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
Assert-OwnedHash $c.app $c.app_sha
$root=Join-Path $c.workspace '.local/sprint21/root'
if($c.pgdata -cne (Join-Path $root 'pgdata08') -or $c.output -cne (Join-Path $root 'crash02') -or $c.pg_port -ne 55448 -or $c.app_port -ne 3135 -or $c.database -cne 'pi_s21_crash'){throw 'crash_scope'}
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'crash_cluster_not_stopped'}
foreach($port in @([int]$c.pg_port,[int]$c.app_port)){$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$probe.Start()}finally{$probe.Stop()}}
$deadline=[DateTimeOffset]$c.phase_deadline_utc
$script:pg=$null;$script:pgClosed=$false;$script:app=$null;$script:appClosed=$true;$script:appJob=$null
$script:appStarts=0
$pgJob=[PiOwnedJob]::new();$success=$false
$dbUrl="host=127.0.0.1 port=$($c.pg_port) user=pi_s21_app dbname=$($c.database) connect_timeout=5 application_name=s21_crash"
function Bounds {if([DateTimeOffset]::UtcNow -ge $deadline -or (Get-PSDrive C).Free -lt 8GB){throw 'crash_deadline_or_free_floor'}}
function Identity($Child,[string]$Program,[bool]$Pg=$false){
 if(!$Child -or $Child.Process.HasExited){throw 'crash_owned_process_not_live'}
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Child.Process.Id)
 Assert-S21ProcessIdentity $Child $Program $row
 if($Pg){[void](Get-OwnedDatadirArgument ([string]$row.CommandLine) $c.pgdata)}
}
function CheckedComplete($Child,[bool]$Zero){
 $r=Complete-OwnedCapturedProcess $Child
 if(($Zero -and $r.native_exit -ne 0) -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'crash_native_exit_or_capture'}
 return $r
}
function Native([string]$Program,[string]$Sha,[string[]]$Arguments,[string]$Label,[hashtable]$Environment=@{},[int]$Seconds=120){
 Bounds
 $r=Invoke-OwnedPhaseCommand $Program $Sha $Arguments $c.workspace $c.output $Label $Environment $Seconds 8MB
 Bounds
 return $r
}
function Sql([string]$Label,[string]$Database,[string]$Statement,[string]$User='pi_s21_app'){
 if($Database -cnotin @('postgres','pi_s21_crash') -or $User -cnotin @('pi_s21_admin','pi_s21_app')){throw 'crash_sql_scope'}
 return Native $c.psql $c.psql_sha @('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$c.pg_port,'-U',$User,'-w','-d',$Database,'-c',$Statement) $Label @{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c search_path=public,pg_catalog';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8'} 15
}
function Snapshot([string]$Label){
 $sql="SELECT json_build_object('projects',(SELECT coalesce(json_agg(row_to_json(p) ORDER BY project_id),'[]'::json) FROM public.pi_projects p),'records',(SELECT coalesce(json_agg(row_to_json(r) ORDER BY project_id,kind,resource_id),'[]'::json) FROM public.pi_records r),'kv',(SELECT coalesce(json_agg(row_to_json(k) ORDER BY key),'[]'::json) FROM public.pi_kv k),'ledger',(SELECT json_agg(row_to_json(m) ORDER BY version) FROM public.pi_schema_migrations m),'sequence',(SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM public.pi_resource_sequence));"
 [void](Sql $Label $c.database $sql)
 return (Join-Path $c.output ($Label+'.stdout'))
}
function StopApp([string]$Program,[string]$Label){
 Identity $script:app $Program
 $script:appJob.Stop()
 if(!$script:app.Process.WaitForExit(10000)){throw 'crash_app_stop_timeout'}
 $r=CheckedComplete $script:app $false;$script:appClosed=$true;$script:appJob.Dispose();$script:appJob=$null
 Write-OwnedJson (Join-Path $c.output ($Label+'-stop.json')) @{controlled_forced_stop=$true;clean_shutdown_not_claimed=$true;pid=$r.pid;native_creation_utc=$r.native_creation_utc;native_exit=$r.native_exit;full_streams_eof=$true}
}
function StartApp([string]$Program,[string]$Sha,[string]$Label){
 Bounds
 if(!$script:appClosed -or $script:appStarts -ge 3){throw 'crash_app_already_live_or_start_limit'}
 $script:appStarts++
 $script:appJob=[PiOwnedJob]::new()
 $script:app=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments @() -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label $Label -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=$dbUrl;PORT=[string]$c.app_port;RUST_LOG='info'}
 $script:appClosed=$false;$script:appJob.Assign($script:app.Handle)
 if(!$script:appJob.Member($script:app.Handle)){throw 'crash_app_job'}
 $ready=$false;$end=[DateTimeOffset]::UtcNow.AddSeconds(30)
 while([DateTimeOffset]::UtcNow -lt $end){
  Bounds
  if($script:app.Process.HasExited){throw 'crash_app_early_exit'}
  $tcp=[Net.Sockets.TcpClient]::new()
  try{$connect=$tcp.ConnectAsync('127.0.0.1',[int]$c.app_port);if($connect.Wait(250) -and $tcp.Connected){$ready=$true;break}}catch{}finally{$tcp.Dispose()}
  Start-Sleep -Milliseconds 100
 }
 if(!$ready){throw 'crash_app_start_timeout'}
 Identity $script:app $Program
}
function Observe([string]$Mode,[string]$Label,[string]$Snapshot=''){
 $argv=@($c.http_helper,'--mode',$Mode,'--output',$c.output,'--label',$Label)
 if($Snapshot){$argv+=@('--snapshot',$Snapshot)}
 [void](Native $c.python $c.python_sha $argv $Label @{} 120)
}
function QuoteSql([string]$Value){return "'"+$Value.Replace('\','/').Replace("'","''")+"'"}
function WaitMarker([string]$Path,[int]$Seconds){
 $end=[DateTimeOffset]::UtcNow.AddSeconds($Seconds)
 while([DateTimeOffset]::UtcNow -lt $end){
  Bounds
  if($script:pg.Process.HasExited -or $script:app.Process.HasExited){throw 'crash_marker_process_exit'}
  if(Test-Path -LiteralPath $Path){
   try{$raw=[IO.File]::ReadAllText($Path);if($raw.Length -gt 4096){throw 'crash_marker_capacity'};if($raw.EndsWith("`n")){return $raw}}catch [IO.IOException]{}
  }
  Start-Sleep -Milliseconds 20
 }
 throw 'crash_marker_timeout'
}
$holder=$null;$holderClosed=$false;$watcher=$null;$watcherClosed=$false;$uploader=$null;$uploaderClosed=$false
$barrierJob=[PiOwnedJob]::new();$triggerInstalled=$false;$key=21321001
try{
 $script:pg=Start-OwnedCapturedProcess -Program $c.postgres -ProgramSha256 $c.postgres_sha -Arguments @('-D',$c.pgdata,'-h','127.0.0.1','-p',[string]$c.pg_port,'-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'postgres' -MaxOutputBytes 8MB
 $pgJob.Assign($script:pg.Handle);if(!$pgJob.Member($script:pg.Handle)){throw 'crash_pg_job'}
 $ready=$false;$pgEnd=[DateTimeOffset]::UtcNow.AddSeconds(30)
 while([DateTimeOffset]::UtcNow -lt $pgEnd){
  Bounds;if($script:pg.Process.HasExited){throw 'crash_pg_early_exit'};$tcp=[Net.Sockets.TcpClient]::new()
  try{$connect=$tcp.ConnectAsync('127.0.0.1',[int]$c.pg_port);if($connect.Wait(250) -and $tcp.Connected){$ready=$true;break}}catch{}finally{$tcp.Dispose()};Start-Sleep -Milliseconds 100
 }
 if(!$ready){throw 'crash_pg_start_timeout'}
 [void](Wait-S21PostgresReady $c $script:pg 20)
 Identity $script:pg $c.postgres $true
 [void](Sql 'owned-cluster' 'postgres' "SELECT current_setting('data_directory')" 'pi_s21_admin')
 $observed=[IO.File]::ReadAllText((Join-Path $c.output 'owned-cluster.stdout')).Trim()
 if(!([IO.Path]::GetFullPath($observed)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'crash_connected_cluster_identity'}
 [void](Sql 'create-crash-db' 'postgres' 'CREATE DATABASE pi_s21_crash OWNER pi_s21_app' 'pi_s21_admin')
 StartApp $c.app $c.app_sha 'app-before-crash'
 Observe 'seed' 'http-seed'
 [void](Snapshot 'seed-committed')
 $triggerSql=@'
CREATE FUNCTION public.s21_conversion_barrier() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.kind='conversion' AND NEW.document->>'payload' IS NOT NULL THEN PERFORM pg_advisory_xact_lock(21321001::bigint); END IF; RETURN NEW; END $$;
CREATE TRIGGER s21_conversion_barrier BEFORE INSERT OR UPDATE ON public.pi_records FOR EACH ROW EXECUTE FUNCTION public.s21_conversion_barrier();
'@
 [void](Sql 'barrier-install' $c.database $triggerSql 'pi_s21_admin');$triggerInstalled=$true
 $heldPath=Join-Path $c.output 'barrier-held.marker';$waitPath=Join-Path $c.output 'barrier-waiting.json'
 $psqlArgs=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_s21_admin','-w','-d',$c.database,'-f','-')
 $barrierEnv=@{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c idle_in_transaction_session_timeout=10000';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8';PGAPPNAME='s21_barrier_hold'}
 $holder=Start-OwnedCapturedProcess -Program $c.psql -ProgramSha256 $c.psql_sha -Arguments $psqlArgs -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'barrier-holder' -MaxOutputBytes 1MB -Environment $barrierEnv -RedirectInput $true
 $barrierJob.Assign($holder.Handle);if(!$barrierJob.Member($holder.Handle)){throw 'crash_holder_job'}
 $holder.Process.StandardInput.WriteLine("BEGIN; SELECT pg_advisory_xact_lock($key`::bigint); COPY (SELECT 'HELD') TO $(QuoteSql $heldPath);")
 $holder.Process.StandardInput.WriteLine('\echo READY');$holder.Process.StandardInput.Flush()
 if((WaitMarker $heldPath 5).Trim() -cne 'HELD'){throw 'crash_holder_not_ready'}
 # Capture app identity before admission; the retained job/handle remain authoritative.
 Identity $script:app $c.app
 $watchSql=@'
DO $watch$ DECLARE item record; until_time timestamptz:=clock_timestamp()+interval '4 seconds'; BEGIN LOOP SELECT l.pid,a.application_name INTO item FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE l.locktype='advisory' AND l.database=(SELECT oid FROM pg_database WHERE datname='pi_s21_crash') AND l.classid=0 AND l.objid=21321001 AND l.objsubid=1 AND NOT l.granted AND a.usename='pi_s21_app' AND a.application_name='s21_crash' LIMIT 1; IF FOUND THEN EXECUTE format('COPY (SELECT json_build_object(''waiter_pid'',%s,''observed_at'',clock_timestamp(),''database'',''pi_s21_crash'',''key'',21321001,''granted'',false,''application_name'',''s21_crash'')) TO %L',item.pid,MARKER_PATH); RETURN; END IF; IF clock_timestamp()>=until_time THEN RAISE EXCEPTION 'barrier waiter not observed'; END IF; PERFORM pg_sleep(0.01); END LOOP; END $watch$;
'@
 $watchSql=$watchSql.Replace('MARKER_PATH',(QuoteSql $waitPath))
 $watchArgs=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_s21_admin','-w','-d',$c.database,'-c',$watchSql)
 $watchEnv=@{};foreach($entry in $barrierEnv.GetEnumerator()){$watchEnv[$entry.Key]=$entry.Value};$watchEnv.PGAPPNAME='s21_barrier_watch'
 $watcher=Start-OwnedCapturedProcess -Program $c.psql -ProgramSha256 $c.psql_sha -Arguments $watchArgs -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'barrier-watcher' -MaxOutputBytes 1MB -Environment $watchEnv
 $barrierJob.Assign($watcher.Handle);if(!$barrierJob.Member($watcher.Handle)){throw 'crash_watcher_job'}
 $uploader=Start-OwnedCapturedProcess -Program $c.python -ProgramSha256 $c.python_sha -Arguments @($c.http_helper,'--mode','submit','--output',$c.output) -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'http-blocked-submit' -MaxOutputBytes 1MB
 $barrierJob.Assign($uploader.Handle);if(!$barrierJob.Member($uploader.Handle)){throw 'crash_uploader_job'}
 $marker=(WaitMarker $waitPath 5)|ConvertFrom-Json -AsHashtable -DateKind String
 if($marker.database -cne $c.database -or $marker.key -ne $key -or $marker.granted -ne $false -or $marker.application_name -cne 's21_crash' -or $marker.waiter_pid -lt 1){throw 'crash_waiter_marker_identity'}
 $observedAt=[DateTimeOffset]::Parse([string]$marker.observed_at)
 Identity $script:app $c.app
 $killAt=[DateTimeOffset]::UtcNow
 if(($killAt-$observedAt).TotalMilliseconds -lt 0 -or ($killAt-$observedAt).TotalMilliseconds -gt 1500){throw 'crash_precommit_kill_window_missed'}
 $script:appJob.Stop()
 if(!$script:app.Process.WaitForExit(10000)){throw 'crash_precommit_app_stop_timeout'}
 $crashed=CheckedComplete $script:app $false;$script:appClosed=$true;$script:appJob.Dispose();$script:appJob=$null
 Write-OwnedJson (Join-Path $c.output 'precommit-native-crash.json') @{observed_at=$observedAt.ToUniversalTime().ToString('o');kill_called_at=$killAt.ToUniversalTime().ToString('o');observed_to_kill_ms=($killAt-$observedAt).TotalMilliseconds;backend_pid=$marker.waiter_pid;app_pid=$crashed.pid;app_creation_utc=$crashed.native_creation_utc;native_exit=$crashed.native_exit;full_streams_eof=$true;actual_ungranted_advisory_wait=$true;app_statement_timeout_ms=5000;app_lock_timeout_ms=2000;production_delay_flags_used=$false;clean_shutdown_not_claimed=$true}
 $holder.Process.StandardInput.WriteLine('COMMIT;');$holder.Process.StandardInput.WriteLine('\quit');$holder.Process.StandardInput.Close()
 if(!$holder.Process.WaitForExit(10000)){throw 'crash_holder_release_timeout'};[void](CheckedComplete $holder $true);$holderClosed=$true
 if(!$watcher.Process.WaitForExit(10000)){throw 'crash_watcher_exit_timeout'};[void](CheckedComplete $watcher $true);$watcherClosed=$true
 if(!$uploader.Process.WaitForExit(10000)){throw 'crash_uploader_exit_timeout'};[void](CheckedComplete $uploader $true);$uploaderClosed=$true
 [void](Sql 'barrier-remove' $c.database 'DROP TRIGGER s21_conversion_barrier ON public.pi_records; DROP FUNCTION public.s21_conversion_barrier();' 'pi_s21_admin');$triggerInstalled=$false
 $crashSnapshot=Snapshot 'after-precommit-crash'
 Observe 'check-crashed' 'check-precommit' $crashSnapshot
 StartApp $c.app $c.app_sha 'app-after-precommit-crash'
 Observe 'recover' 'http-recover-retry'
 $committed=Snapshot 'retry-committed-before-second-crash'
 Observe 'check-completed' 'check-pair-before-second-crash' $committed
 StopApp $c.app 'actual-postcommit-crash'
 StartApp $c.app $c.app_sha 'app-after-postcommit-crash'
 Observe 'verify' 'http-verify-second-restart'
 $final=Snapshot 'after-second-restart'
 Observe 'check-completed' 'check-pair-after-second-restart' $final
 StopApp $c.app 'fixture-final-stop'
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $success=$true
}catch{
 $mainFailure=$_
 try{Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{status='ACTUAL_MAIN_FAILURE';utc=[DateTimeOffset]::UtcNow.ToString('o');message=$mainFailure.Exception.Message;base_exception_type=$mainFailure.Exception.GetBaseException().GetType().FullName;position=$mainFailure.InvocationInfo.PositionMessage;script_stack_trace=$mainFailure.ScriptStackTrace;config_sha256=$PhaseConfigSha}}catch{Write-Warning ('crash_primary_failure_receipt_diagnostic: '+$_.Exception.Message)}
 throw $mainFailure
}finally{
 try{
  if($script:app -and !$script:appClosed){if(!$script:app.Process.HasExited){Identity $script:app $c.app;$script:appJob.Stop()};if(!$script:app.Process.WaitForExit(10000)){throw 'crash_final_app_stop'};[void](CheckedComplete $script:app $false);$script:appClosed=$true}
  if($holder -and !$holderClosed){if(!$holder.Process.HasExited){$holder.Process.StandardInput.WriteLine('ROLLBACK;');$holder.Process.StandardInput.WriteLine('\quit');$holder.Process.StandardInput.Close()};if(!$holder.Process.WaitForExit(10000)){throw 'crash_final_holder_stop'};[void](CheckedComplete $holder $false);$holderClosed=$true}
  $pendingAux=@();if($watcher -and !$watcherClosed){$pendingAux+=,$watcher};if($uploader -and !$uploaderClosed){$pendingAux+=,$uploader}
  foreach($child in $pendingAux){if(!$child.Process.HasExited){$barrierJob.Stop();break}}
  foreach($child in $pendingAux){if($child.Process.WaitForExit(10000)){[void](CheckedComplete $child $false)}else{throw 'crash_aux_stop_timeout'}}
  if($triggerInstalled -and $script:pg -and !$script:pg.Process.HasExited){[void](Sql 'barrier-remove-after-failure' $c.database 'DROP TRIGGER IF EXISTS s21_conversion_barrier ON public.pi_records; DROP FUNCTION IF EXISTS public.s21_conversion_barrier();' 'pi_s21_admin');$triggerInstalled=$false}
  if($script:pg -and !$script:pgClosed){if(!$script:pg.Process.HasExited){Identity $script:pg $c.postgres $true;[void](Invoke-OwnedPhaseCommand $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') $c.workspace $c.output 'pg-stop' @{} 20 2MB)};if(!$script:pg.Process.WaitForExit(10000)){throw 'crash_final_pg_stop'};[void](CheckedComplete $script:pg $true);$script:pgClosed=$true}
 }catch{
  $original=$_
  try{if($script:appJob){$script:appJob.Stop()};$barrierJob.Stop();$pgJob.Stop()}catch{Write-Warning ('crash_owned_stop_diagnostic: '+$_.Exception.Message)}
  throw $original
 }finally{if($script:appJob){$script:appJob.Dispose()};$barrierJob.Dispose();$pgJob.Dispose()}
}
if($success){Write-OwnedJson (Join-Path $c.output 'crash-proof.json') @{status='ACTUAL_STOCK_PROCESS_PRECOMMIT_AND_POSTCOMMIT_CRASH';config_sha256=$PhaseConfigSha;app_sha256=$c.app_sha;app_starts=$script:appStarts;precommit_wait_observed_and_killed_within_1500ms=$true;retained_input_and_original_pair=$true;retry_new_linked_attempt=$true;completed_pair_survived_second_crash=$true;all_native_streams_eof=$true;test_trigger_removed=$true;production_delay_flags_used=$false;server_left_running=$false;browser_acceptance_not_claimed=$true}}
