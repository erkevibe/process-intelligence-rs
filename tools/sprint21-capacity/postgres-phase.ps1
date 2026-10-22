param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# Fresh private PostgreSQL only. No installation, old data adoption or DROP DATABASE.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $c.workspace 'tools/sprint21/process-identity.psm1') -Force
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $c.workspace 'tools/sprint21-capacity/postgres-readiness.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output
$root=Join-Path $c.workspace '.local/sprint21/root'
if((Split-Path -Parent $c.pgdata) -cne $root -or (Split-Path -Leaf $c.pgdata) -cnotmatch '^pgdata[0-9]{2}$' -or $c.pg_port -lt 55441 -or $c.pg_port -gt 55449){throw 'postgres_scope'}
if(Test-Path -LiteralPath $c.pgdata){throw 'postgres_fresh_data_required'}
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,[int]$c.pg_port)
try{$probe.Start()}finally{$probe.Stop()}
[void](New-OwnedPrivateDirectory $c.pgdata)
$dbs=@('pi_s21_migration','pi_s21_workflow','pi_s21_browser','pi_s21_adversarial','pi_s21_fault','pi_s21_capacity')
$deadline=[DateTimeOffset]$c.phase_deadline_utc
function Check-Bounds {
 if([DateTimeOffset]::UtcNow -ge $deadline -or (Get-PSDrive C).Free -lt 8GB){throw 'postgres_deadline_or_free_floor'}
 if($script:server -and !$script:serverClosed){
  if($script:server.Process.HasExited){throw 'postgres_unexpected_exit'}
  if($script:server.OutCapture.LimitReached -or $script:server.ErrCapture.LimitReached -or $script:server.OutCapture.Pump.IsFaulted -or $script:server.ErrCapture.Pump.IsFaulted){throw 'postgres_capture_fault'}
 }
}
function Native([string]$Program,[string]$Sha,[string[]]$Arguments,[string]$Label,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=4MB){
 Check-Bounds
 $r=Invoke-OwnedPhaseCommand $Program $Sha $Arguments $c.workspace $c.output $Label $Environment $Seconds $Cap
 Check-Bounds
 return $r
}
function Sql([string]$Database,[string]$Label,[string]$Statement,[string]$User='pi_s21_admin'){
 if($Database -cnotin ($dbs+@('postgres')) -or $User -cnotin @('pi_s21_admin','pi_s21_app')){throw 'postgres_sql_scope'}
 return Native $c.psql $c.psql_sha @('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$c.pg_port,'-U',$User,'-w','-d',$Database,'-c',$Statement) $Label @{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c search_path=public,pg_catalog';PGCONNECT_TIMEOUT='5'} 15 1MB
}
function Assert-ServerIdentity {
 if(!$script:server -or $script:serverClosed -or $script:server.Process.HasExited){throw 'postgres_not_owned_live'}
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$script:server.Process.Id)
 if(!$row -or !([IO.Path]::GetFullPath([string]$row.ExecutablePath)).Equals([IO.Path]::GetFullPath([string]$c.postgres),[StringComparison]::OrdinalIgnoreCase)){throw 'postgres_image_identity'}
 Assert-S21ProcessIdentity $script:server $c.postgres $row
 [void](Get-OwnedDatadirArgument ([string]$row.CommandLine) $c.pgdata)
}
$script:server=$null;$script:serverClosed=$false;$serverJob=[PiOwnedJob]::new();$succeeded=$false;$stopProof=$null
try{
 [void](Native $c.initdb $c.initdb_sha @('-D',$c.pgdata,'-U','pi_s21_admin','--auth-local=trust','--auth-host=trust','--encoding=UTF8','--locale=C','--no-instructions') 'initdb' @{} 120 4MB)
 Assert-OwnedPrivateDirectory $c.pgdata
 $script:server=Start-OwnedCapturedProcess -Program $c.postgres -ProgramSha256 $c.postgres_sha -Arguments @('-D',$c.pgdata,'-h','127.0.0.1','-p',[string]$c.pg_port,'-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'postgres' -MaxOutputBytes 8MB
 $serverJob.Assign($script:server.Handle)
 if(!$serverJob.Member($script:server.Handle)){throw 'postgres_job_membership'}
 $readyUntil=[DateTimeOffset]::UtcNow.AddSeconds(30);$connected=$false
 while([DateTimeOffset]::UtcNow -lt $readyUntil){
  Check-Bounds
  $tcp=[Net.Sockets.TcpClient]::new()
  try{$connect=$tcp.ConnectAsync('127.0.0.1',[int]$c.pg_port);if($connect.Wait(250) -and $tcp.Connected){$connected=$true;break}}catch{}finally{$tcp.Dispose()}
  Start-Sleep -Milliseconds 100
 }
 if(!$connected){throw 'postgres_tcp_timeout'}
 [void](Wait-S21PostgresReady $c $script:server 20)
 Assert-ServerIdentity
 [void](Sql 'postgres' 'sql-ready' "SELECT current_database(),current_user,inet_server_addr()::text,inet_server_port(),current_setting('server_version'),pg_postmaster_start_time()::text")
 [void](Sql 'postgres' 'sql-owned-directory' "SELECT current_setting('data_directory')")
 $observedData=[IO.File]::ReadAllText((Join-Path $c.output 'sql-owned-directory.stdout')).Trim()
 if(!([IO.Path]::GetFullPath($observedData)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'postgres_connected_cluster_identity'}
 [void](Sql 'postgres' 'create-app-role' 'CREATE ROLE pi_s21_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION')
 foreach($db in $dbs){[void](Sql 'postgres' ('create-'+$db.Replace('_','-')) ('CREATE DATABASE '+$db+' OWNER pi_s21_app'))}
 [void](Sql 'pi_s21_workflow' 'app-transaction-probe' "BEGIN; CREATE TABLE public.s21_transaction_probe(v integer); INSERT INTO public.s21_transaction_probe VALUES(7); ROLLBACK; SELECT current_user,rolsuper,rolcreatedb,rolcreaterole,to_regclass('public.s21_transaction_probe') IS NULL FROM pg_roles WHERE rolname=current_user" 'pi_s21_app')
 $probeText=[IO.File]::ReadAllText((Join-Path $c.output 'app-transaction-probe.stdout')).Trim()
 if($probeText -cne 'pi_s21_app|f|f|f|t'){throw 'postgres_app_privilege_or_rollback_probe'}
 foreach($task in $c.acceptance_tasks){
  if($task.database -cnotin $dbs -or [string]$task.environment_name -notmatch '^S21_[A-Z_]+DATABASE_URL$' -or [string]$task.label -notmatch '^[a-z][a-z0-9-]{0,63}$'){throw 'postgres_test_scope'}
  $args=@('test','--offline','--locked','--manifest-path',(Join-Path $c.workspace 'Cargo.toml'),'--target-dir',$c.target,'--jobs','2')
  if($task.ContainsKey('integration_test')){if([string]$task.integration_test -notmatch '^[a-z0-9_]+$'){throw 'postgres_test_name'};$args+=@('--test',[string]$task.integration_test)}else{$args+='--lib'}
  if([string]$task.filter -notmatch '^[A-Za-z0-9_:]+$'){throw 'postgres_test_filter'}
  $args+=@([string]$task.filter,'--','--ignored','--exact','--test-threads=1','--nocapture')
  $envAdd=@{RAYON_NUM_THREADS='1'}
  $envAdd[[string]$task.environment_name]="postgresql://pi_s21_app@127.0.0.1:$($c.pg_port)/$($task.database)"
  if($task.ContainsKey('evidence_directory')){
   $expectedEvidence=Join-Path $root ('evidence-'+[string]$task.label)
   $evidenceNames=@{S21_WORKFLOW_DATABASE_URL='S21_WORKFLOW_EVIDENCE';S21_ADVERSARIAL_DATABASE_URL='S21_ADVERSARIAL_EVIDENCE';S21_FAULT_DATABASE_URL='S21_FAULT_EVIDENCE';S21_CAPACITY_DATABASE_URL='S21_CAPACITY_EVIDENCE'}
   if($task.evidence_directory -cne $expectedEvidence -or !$evidenceNames.ContainsKey([string]$task.environment_name)){throw 'postgres_evidence_scope'}
   [void](New-OwnedPrivateDirectory $expectedEvidence)
   $envAdd[$evidenceNames[[string]$task.environment_name]]=$expectedEvidence
  }
  [void](Native $c.cargo $c.cargo_sha $args ([string]$task.label) $envAdd 900 8MB)
  $testOutput=[IO.File]::ReadAllText((Join-Path $c.output ([string]$task.label+'.stdout')))
  if($testOutput -notmatch '(?m)^running 1 test\s*$' -or $testOutput -notmatch '(?m)^test result: ok\. 1 passed; 0 failed; 0 ignored;'){throw 'postgres_test_not_exactly_one_executed'}
 }
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $succeeded=$true
}finally{
 try{
  if($script:server -and !$script:serverClosed){
   if(!$script:server.Process.HasExited){
    Assert-ServerIdentity
    # pg_ctl stops the positively identified existing server; it never starts children.
    [void](Invoke-OwnedPhaseCommand $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') $c.workspace $c.output 'pg-stop' @{} 20 2MB)
   }
   if(!$script:server.Process.WaitForExit(10000)){throw 'postgres_stop_timeout'}
   $stopProof=Complete-OwnedCapturedProcess $script:server
   $script:serverClosed=$true
   if($stopProof.native_exit -ne 0 -or !$stopProof.stdout_complete -or !$stopProof.stderr_complete -or $stopProof.output_limit -or $stopProof.capture_fault -or $stopProof.drain_timeout){throw 'postgres_stop_or_streams_failed'}
  }
 }catch{
  $stopError=$_
  try{
   $serverJob.Stop()
   if($script:server -and !$script:serverClosed -and $script:server.Process.WaitForExit(10000)){
    [void](Complete-OwnedCapturedProcess $script:server);$script:serverClosed=$true
   }
  }catch{Write-Warning ('postgres_owned_fallback_diagnostic: '+$_.Exception.Message)}
  throw $stopError
 }finally{$serverJob.Dispose()}
}
if($succeeded){Write-OwnedJson (Join-Path $c.output 'postgres-proof.json') @{status='ACTUAL_FRESH_POSTGRES_AND_SELECTED_TESTS';config_sha256=$PhaseConfigSha;port=$c.pg_port;database_names=$dbs;app_nonsuperuser_rollback_probe=$true;test_count=@($c.acceptance_tasks).Count;postgres_native_exit=$stopProof.native_exit;postgres_full_streams_eof=$true;cluster_retained=$true;server_left_running=$false;browser_acceptance_not_claimed=$true}}
