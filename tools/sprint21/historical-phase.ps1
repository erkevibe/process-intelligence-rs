param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'process-identity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'postgres-readiness-v2.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedHash $c.app $c.app_sha;Assert-OwnedHash $c.old_app $c.old_app_sha
$root=Join-Path $c.workspace '.local/sprint21/root'
if($c.pgdata -cne (Join-Path $root 'pgdata08') -or $c.output -cne (Join-Path $root 'historical04') -or $c.pg_port -ne 55448 -or $c.app_port -ne 3132 -or $c.database -cne 'pi_s21_historical04' -or $c.old_app -cne (Join-Path $c.workspace '.local/sprint20/root/target/debug/process-intelligence-rs.exe')){throw 'historical_scope'}
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'historical_cluster_not_stopped'}
foreach($port in @([int]$c.pg_port,[int]$c.app_port)){$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$probe.Start()}finally{$probe.Stop()}}
$deadline=[DateTimeOffset]$c.phase_deadline_utc
$script:pg=$null;$script:pgClosed=$false;$script:app=$null;$script:appClosed=$true;$script:appJob=$null
$pgJob=[PiOwnedJob]::new();$success=$false
$dbUrl="host=127.0.0.1 port=$($c.pg_port) user=pi_s21_app dbname=$($c.database) connect_timeout=5 application_name=s21_historical"
function Bounds {if([DateTimeOffset]::UtcNow -ge $deadline -or (Get-PSDrive C).Free -lt 8GB){throw 'historical_deadline_or_free_floor'}}
function Identity($Child,[string]$Program,[bool]$Pg=$false){
 if(!$Child -or $Child.Process.HasExited){throw 'historical_owned_process_not_live'}
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Child.Process.Id)
 Assert-S21ProcessIdentity $Child $Program $row
 if($Pg){[void](Get-OwnedDatadirArgument ([string]$row.CommandLine) $c.pgdata)}
}
function CheckedComplete($Child,[bool]$Zero){
 $r=Complete-OwnedCapturedProcess $Child
 if(($Zero -and $r.native_exit -ne 0) -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'historical_native_exit_or_capture'}
 return $r
}
function Native([string]$Program,[string]$Sha,[string[]]$Arguments,[string]$Label,[hashtable]$Environment=@{},[int]$Seconds=120){
 Bounds
 $r=Invoke-OwnedPhaseCommand $Program $Sha $Arguments $c.workspace $c.output $Label $Environment $Seconds 8MB
 Bounds
 return $r
}
function Sql([string]$Label,[string]$Database,[string]$Statement,[string]$User='pi_s21_app'){
 if($Database -cnotin @('postgres','pi_s21_historical04') -or $User -cnotin @('pi_s21_admin','pi_s21_app')){throw 'historical_sql_scope'}
 return Native $c.psql $c.psql_sha @('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$c.pg_port,'-U',$User,'-w','-d',$Database,'-c',$Statement) $Label @{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c search_path=public,pg_catalog';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8'} 15
}
function Snapshot([string]$Label){
 $sql="SELECT json_build_object('projects',(SELECT coalesce(json_agg(row_to_json(p) ORDER BY project_id),'[]'::json) FROM public.pi_projects p),'records',(SELECT coalesce(json_agg(row_to_json(r) ORDER BY project_id,kind,resource_id),'[]'::json) FROM public.pi_records r),'kv',(SELECT coalesce(json_agg(row_to_json(k) ORDER BY key),'[]'::json) FROM public.pi_kv k),'ledger',(SELECT json_agg(row_to_json(m) ORDER BY version) FROM public.pi_schema_migrations m),'sequence',(SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM public.pi_resource_sequence));"
 [void](Sql $Label $c.database $sql)
 return (Join-Path $c.output ($Label+'.stdout'))
}
function Observer([string]$Mode,[string]$Label,[string]$Before='',[string]$After='',[string]$Version=''){
 $argv=@($c.http_helper,'--mode',$Mode,'--output',$c.output,'--label',$Label)
 if($Before){$argv+=@('--before',$Before,'--after',$After)}
 if($Version){$argv+=@('--expected-version',$Version)}
 [void](Native $c.python $c.python_sha $argv $Label @{} 120)
}
function StopApp([string]$Program,[string]$Label){
 Identity $script:app $Program
 $script:appJob.Stop()
 if(!$script:app.Process.WaitForExit(10000)){throw 'historical_app_stop_timeout'}
 $r=CheckedComplete $script:app $false;$script:appClosed=$true;$script:appJob.Dispose();$script:appJob=$null
 Write-OwnedJson (Join-Path $c.output ($Label+'-stop.json')) @{controlled_forced_stop=$true;clean_shutdown_not_claimed=$true;pid=$r.pid;native_creation_utc=$r.native_creation_utc;native_exit=$r.native_exit;full_streams_eof=$true}
}
function StartApp([string]$Program,[string]$Sha,[string]$Label){
 Bounds
 if(!$script:appClosed){throw 'historical_app_already_live'}
 $script:appJob=[PiOwnedJob]::new()
 $script:app=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments @() -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label $Label -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=$dbUrl;PORT=[string]$c.app_port;RUST_LOG='info'}
 $script:appClosed=$false;$script:appJob.Assign($script:app.Handle)
 if(!$script:appJob.Member($script:app.Handle)){throw 'historical_app_job'}
 $ready=$false;$end=[DateTimeOffset]::UtcNow.AddSeconds(30)
 while([DateTimeOffset]::UtcNow -lt $end){
  Bounds
  if($script:app.Process.HasExited){throw 'historical_app_early_exit'}
  $tcp=[Net.Sockets.TcpClient]::new()
  try{$connect=$tcp.ConnectAsync('127.0.0.1',[int]$c.app_port);if($connect.Wait(250) -and $tcp.Connected){$ready=$true;break}}catch{}finally{$tcp.Dispose()}
  Start-Sleep -Milliseconds 100
 }
 if(!$ready){throw 'historical_app_start_timeout'}
 Identity $script:app $Program
}
try{
 $script:pg=Start-OwnedCapturedProcess -Program $c.postgres -ProgramSha256 $c.postgres_sha -Arguments @('-D',$c.pgdata,'-h','127.0.0.1','-p',[string]$c.pg_port,'-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'postgres' -MaxOutputBytes 8MB
 $pgJob.Assign($script:pg.Handle);if(!$pgJob.Member($script:pg.Handle)){throw 'historical_pg_job'}
 $ready=$false;$pgEnd=[DateTimeOffset]::UtcNow.AddSeconds(30)
 while([DateTimeOffset]::UtcNow -lt $pgEnd){
  Bounds;if($script:pg.Process.HasExited){throw 'historical_pg_early_exit'};$tcp=[Net.Sockets.TcpClient]::new()
  try{$connect=$tcp.ConnectAsync('127.0.0.1',[int]$c.pg_port);if($connect.Wait(250) -and $tcp.Connected){$ready=$true;break}}catch{}finally{$tcp.Dispose()};Start-Sleep -Milliseconds 100
 }
 if(!$ready){throw 'historical_pg_start_timeout'}
 [void](Wait-S21PostgresReady $c $script:pg 20)
 Identity $script:pg $c.postgres $true
 [void](Sql 'owned-cluster' 'postgres' "SELECT current_setting('data_directory')" 'pi_s21_admin')
 $observed=[IO.File]::ReadAllText((Join-Path $c.output 'owned-cluster.stdout')).Trim()
 if(!([IO.Path]::GetFullPath($observed)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'historical_connected_cluster_identity'}
 # CREATE alone refuses a pre-existing database. Nothing is dropped or adopted.
 [void](Sql 'create-historical-db' 'postgres' 'CREATE DATABASE pi_s21_historical04 OWNER pi_s21_app' 'pi_s21_admin')
 StartApp $c.old_app $c.old_app_sha 'old075-seed'
 Observer 'seed' 'http-old075-seed' '' '' '0.7.5'
 StopApp $c.old_app 'old075-seed'
 $before=Snapshot 'before-migration'
 [void](Native $c.app $c.app_sha @('--migrate-storage') 'offline-migration' @{PI_DATABASE_URL=$dbUrl} 120)
 $after=Snapshot 'after-migration'
 Observer 'compare-migration' 'migration-values' $before $after
 [void](Native $c.app $c.app_sha @('--migrate-storage') 'offline-migration-repeat' @{PI_DATABASE_URL=$dbUrl} 120)
 $repeat=Snapshot 'after-repeat'
 Observer 'compare-identical' 'idempotent-values' $after $repeat
 StartApp $c.app $c.app_sha 'new080-readback'
 Observer 'verify' 'http-new080-readback' '' '' '0.8.0'
 StopApp $c.app 'new080-readback'
 $oldBefore=Snapshot 'before-old-refusal'
 # Run the actual historical binary, observing for any listener while it refuses V3.
 $script:appJob=[PiOwnedJob]::new()
 $script:app=Start-OwnedCapturedProcess -Program $c.old_app -ProgramSha256 $c.old_app_sha -Arguments @() -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'old075-v3-refusal' -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=$dbUrl;PORT=[string]$c.app_port;RUST_LOG='info'}
 $script:appClosed=$false;$refusalAssignment='assigned'
 try{$script:appJob.Assign($script:app.Handle)}catch{
  if($_.Exception.GetBaseException().Message -cne 'job_assign' -or !$script:app.Process.HasExited){throw}
  $refusalAssignment='already_exited_before_nested_assignment'
 }
 if(!$script:app.Process.HasExited -and !$script:appJob.Member($script:app.Handle) -and !$script:app.Process.HasExited){throw 'historical_refusal_live_job'}
 $refusalEnd=[DateTimeOffset]::UtcNow.AddSeconds(15);$listenerObserved=$false
 while(!$script:app.Process.HasExited){
  Bounds;if([DateTimeOffset]::UtcNow -ge $refusalEnd){throw 'historical_old_refusal_timeout'}
  if($script:app.OutCapture.LimitReached -or $script:app.ErrCapture.LimitReached){throw 'historical_refusal_output_cap'}
  $tcp=[Net.Sockets.TcpClient]::new()
  $connected=$false
  try{$connect=$tcp.ConnectAsync('127.0.0.1',[int]$c.app_port);$connected=$connect.Wait(100) -and $tcp.Connected}catch{
   $cause=$_.Exception.GetBaseException()
   if($cause -isnot [Net.Sockets.SocketException] -or $cause.SocketErrorCode -ne [Net.Sockets.SocketError]::ConnectionRefused){throw}
  }finally{$tcp.Dispose()}
  if($connected){$listenerObserved=$true;throw 'historical_old_refusal_listener'}
  Start-Sleep -Milliseconds 50
 }
 $refusal=CheckedComplete $script:app $false;$script:appClosed=$true;$script:appJob.Dispose();$script:appJob=$null
 if($refusal.native_exit -ne 1 -or $listenerObserved){throw 'historical_old_binary_did_not_refuse'}
 $refusalText=[IO.File]::ReadAllText((Join-Path $c.output 'old075-v3-refusal.stderr'))
 if(!$refusalText.Contains('Схема базы не поддерживается или повреждена',[StringComparison]::Ordinal)){throw 'historical_old_refusal_reason_not_schema'}
 $portProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,[int]$c.app_port);try{$portProbe.Start()}finally{$portProbe.Stop()}
 $oldAfter=Snapshot 'after-old-refusal'
 Observer 'compare-identical' 'old-refusal-unchanged' $oldBefore $oldAfter
 Write-OwnedJson (Join-Path $c.output 'old-binary-refusal-proof.json') @{old_version='0.7.5';old_sha256=$c.old_app_sha;new_version='0.8.0';new_sha256=$c.app_sha;actual_native_exit=$refusal.native_exit;nested_job_assignment=$refusalAssignment;schema_refusal_reason_matched=$true;listener_observed=$listenerObserved;listener_check='bounded non-atomic TCP sampling plus final available-bind probe';database_values_unchanged=$true;browser_acceptance_not_claimed=$true}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $success=$true
}catch{
 $mainFailure=$_
 try{
  Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{status='ACTUAL_MAIN_FAILURE';utc=[DateTimeOffset]::UtcNow.ToString('o');exception_type=$mainFailure.Exception.GetType().FullName;base_exception_type=$mainFailure.Exception.GetBaseException().GetType().FullName;message=$mainFailure.Exception.Message;fully_qualified_error_id=$mainFailure.FullyQualifiedErrorId;position=$mainFailure.InvocationInfo.PositionMessage;script_stack_trace=$mainFailure.ScriptStackTrace;config_sha256=$PhaseConfigSha;earlier_attempt_cause_not_inferred=$true}
 }catch{Write-Warning ('historical_primary_failure_receipt_diagnostic: '+$_.Exception.Message)}
 throw $mainFailure
}finally{
 try{
  if($script:app -and !$script:appClosed){
   if(!$script:app.Process.HasExited){Identity $script:app $script:app.Record.program;$script:appJob.Stop()}
   if(!$script:app.Process.WaitForExit(10000)){throw 'historical_final_app_stop'}
   [void](CheckedComplete $script:app $false);$script:appClosed=$true
  }
  if($script:pg -and !$script:pgClosed){
   if(!$script:pg.Process.HasExited){Identity $script:pg $c.postgres $true;[void](Invoke-OwnedPhaseCommand $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') $c.workspace $c.output 'pg-stop' @{} 20 2MB)}
   if(!$script:pg.Process.WaitForExit(10000)){throw 'historical_final_pg_stop'};[void](CheckedComplete $script:pg $true);$script:pgClosed=$true
  }
 }catch{
  $original=$_
  try{if($script:appJob){$script:appJob.Stop()};$pgJob.Stop()}catch{Write-Warning ('historical_owned_stop_diagnostic: '+$_.Exception.Message)}
  foreach($child in @($script:app,$script:pg)){try{if($child -and $child.Process -and $child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning ('historical_capture_cleanup_diagnostic: '+$_.Exception.Message)}}
  throw $original
 }finally{if($script:appJob){$script:appJob.Dispose()};$pgJob.Dispose()}
}
if($success){Write-OwnedJson (Join-Path $c.output 'historical-proof.json') @{status='ACTUAL_075_POPULATED_V2_TO_080_V3';config_sha256=$PhaseConfigSha;old_sha256=$c.old_app_sha;new_sha256=$c.app_sha;historical_values_versions_and_ledger_preserved=$true;repeat_idempotent=$true;http_export_identical=$true;actual_old_binary_refused_v3=$true;all_native_streams_eof=$true;server_left_running=$false;browser_acceptance_not_claimed=$true}}
