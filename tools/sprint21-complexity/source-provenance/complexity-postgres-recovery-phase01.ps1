param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# PostgreSQL alone handles its stale PID file and WAL; old uncaptured exit stays UNKNOWN.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'complexity_recovery_config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($module in @('owned-runtime.psm1','owned-phase-support.psm1','process-identity.psm1')){Import-Module (Join-Path $c.workspace ('tools/sprint21/'+$module)) -Force -DisableNameChecking}
Import-Module (Join-Path $c.workspace 'tools/sprint21-capacity/postgres-readiness.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$root=Join-Path $c.workspace '.local/sprint21/root';$oldRoot=Join-Path $root 'complexity-measure01'
if($c.pgdata -cne (Join-Path $root 'pgdata11') -or $c.pg_port -ne 55449 -or $c.output -cne (Join-Path $root 'complexity-postgres-recovery01') -or $c.retained_start_path -cne (Join-Path $oldRoot 'postgres.start.json')){throw 'complexity_recovery_exact_scope'}
Assert-OwnedPrivateDirectory $c.pgdata;Assert-OwnedPrivateDirectory $c.output
Assert-OwnedHash $c.retained_start_path $c.retained_start_sha
$old=Get-Content -LiteralPath $c.retained_start_path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$oldCreation='2026-10-22T22:30:40.6305015Z'
if($old.pid -ne 23044 -or $old.native_creation_utc -cne $oldCreation -or $null -ne $old.native_exit -or $old.stdout_complete -or $old.stderr_complete -or $old.program_sha256 -cne $c.postgres_sha -or !([IO.Path]::GetFullPath([string]$old.program)).Equals([IO.Path]::GetFullPath([string]$c.postgres),[StringComparison]::OrdinalIgnoreCase)){throw 'complexity_recovery_original_start_binding'}
if(Test-Path -LiteralPath (Join-Path $oldRoot 'postgres.process.json')){throw 'complexity_recovery_unexpected_old_completion_requires_review'}
Assert-OwnedHash (Join-Path $oldRoot 'postgres.stdout') $c.retained_stdout_sha
Assert-OwnedHash (Join-Path $oldRoot 'postgres.stderr') $c.retained_stderr_sha
$ownerPath=Join-Path $oldRoot 'command.process.json';Assert-OwnedHash $ownerPath $c.retained_owner_process_sha
$owner=Get-Content -LiteralPath $ownerPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($owner.pid -ne 40132 -or $owner.native_exit -ne 1 -or !$owner.stdout_complete -or !$owner.stderr_complete -or $owner.output_limit -or $owner.capture_fault -or $owner.drain_timeout){throw 'complexity_recovery_owner_completion_binding'}
$pidPath=Join-Path $c.pgdata 'postmaster.pid'
foreach($pin in $c.pins){if(([IO.Path]::GetFullPath([string]$pin.path)).Equals([IO.Path]::GetFullPath($pidPath),[StringComparison]::OrdinalIgnoreCase)){throw 'complexity_recovery_live_pidfile_not_immutable_pin'}}
Assert-OwnedHash $pidPath $c.pid_file_sha
$lines=[IO.File]::ReadAllLines($pidPath);$epoch=[DateTimeOffset]::ParseExact($oldCreation,'o',[Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
if($lines.Length -ne 8 -or $lines[0] -cne '23044' -or !([IO.Path]::GetFullPath($lines[1])).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase) -or $lines[2] -cne [string]$epoch -or $lines[3] -cne '55449' -or $lines[4] -cne '' -or $lines[5] -cne '127.0.0.1' -or $lines[6] -cne '' -or $lines[7].Trim() -cne 'ready'){throw 'complexity_recovery_stale_pidfile_binding'}
$pidCopy=Join-Path $c.output 'original-postmaster.pid.txt';[IO.File]::Copy($pidPath,$pidCopy,$false);Assert-OwnedHash $pidCopy $c.pid_file_sha
function OldPidAbsent {
 foreach($oldPid in @(23044,39988,41888)){
  $p=$null;try{$p=[Diagnostics.Process]::GetProcessById($oldPid)}catch{if($_.Exception.GetBaseException() -isnot [ArgumentException]){throw}}
  if($p){$p.Dispose();throw 'complexity_recovery_old_pid_present_or_reused'}
 }
}
OldPidAbsent
$rows=@(Get-CimInstance Win32_Process -Filter "Name='postgres.exe'")
if($rows.Count -gt 128){throw 'complexity_recovery_cim_cap'}
foreach($row in $rows){
 if(!$row.CommandLine -or !$row.ExecutablePath){throw 'complexity_recovery_opaque_postgres'}
 $argv=[PiWindowsArguments]::Parse([string]$row.CommandLine)
 for($index=1;$index -lt $argv.Length;$index++){
  $arg=$argv[$index];$dir=$null
  if($arg -ceq '-D' -or $arg -ceq '--pgdata'){if($index+1 -ge $argv.Length){throw 'complexity_recovery_malformed_datadir'};$dir=$argv[++$index]}
  elseif($arg.StartsWith('-D',[StringComparison]::Ordinal) -and $arg.Length -gt 2){$dir=$arg.Substring(2)}
  elseif($arg.StartsWith('--pgdata=',[StringComparison]::Ordinal)){$dir=$arg.Substring(9)}
  if($null -ne $dir){if(!$dir -or ![IO.Path]::IsPathFullyQualified($dir)){throw 'complexity_recovery_relative_or_empty_datadir'};if(([IO.Path]::GetFullPath($dir)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'complexity_recovery_same_datadir_live'}}
 }
}
foreach($port in @(55449,3139)){$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$probe.Start()}finally{$probe.Stop()}}
Write-OwnedJson (Join-Path $c.output 'recovery-preflight.json') @{old_postgres_pid=23044;old_postgres_creation_utc=$oldCreation;old_postgres_native_exit='UNKNOWN';old_postgres_stream_eof='UNKNOWN';old_start_and_raw_stream_bytes_pinned=$true;owner_worker_exit=1;owner_worker_full_streams_eof=$true;owner_exit_not_substituted_for_postgres_exit=$true;old_pid_absent=$true;no_same_datadir_argument_observed=$true;postgres_cim_rows_examined=$rows.Count;ports_free=@(55449,3139);original_pidfile_copy_sha256=$c.pid_file_sha;manual_pid_or_database_edit_used=$false;utc=[DateTimeOffset]::UtcNow.ToString('o')}
$deadline=[DateTimeOffset]$c.phase_deadline_utc
if($deadline -gt [DateTimeOffset]'2026-10-22T22:46:12Z'){throw 'complexity_recovery_original_native_end_exceeded'}
$server=$null;$closed=$false;$job=[PiOwnedJob]::new();$success=$false
function Bounds {if([DateTimeOffset]::UtcNow -ge $deadline -or (Get-PSDrive C).Free -lt 8GB){throw 'complexity_recovery_time_or_free_floor'}}
function Identity($Child){$row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Child.Process.Id);Assert-S21ProcessIdentity $Child $c.postgres $row $c.pgdata}
function Complete-Checked($Child,[bool]$Zero){$r=Complete-OwnedCapturedProcess $Child;if(($Zero -and $r.native_exit -ne 0) -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'complexity_recovery_native_exit_or_capture'};return $r}
try{
 Bounds;OldPidAbsent;Assert-OwnedHash $pidPath $c.pid_file_sha
 $server=Start-OwnedCapturedProcess -Program $c.postgres -ProgramSha256 $c.postgres_sha -Arguments @('-D',$c.pgdata,'-h','127.0.0.1','-p','55449','-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'postgres-recovery' -MaxOutputBytes 8MB
 $job.Assign($server.Handle);if(!$job.Member($server.Handle)){throw 'complexity_recovery_new_job'}
 [void](Wait-S21PostgresReady $c $server 20);Identity $server
 [void](Invoke-OwnedPhaseCommand $c.psql $c.psql_sha @('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','55449','-U','pi_s21_admin','-w','-d','postgres','-c',"SELECT json_build_object('data_directory',current_setting('data_directory'),'database',current_database(),'user',current_user,'port',inet_server_port(),'in_recovery',pg_is_in_recovery())") $c.workspace $c.output 'sql-recovered-readonly' @{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c default_transaction_read_only=on';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8'} 10 1MB)
 $sql=Get-Content -LiteralPath (Join-Path $c.output 'sql-recovered-readonly.stdout') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($sql.database -cne 'postgres' -or $sql.user -cne 'pi_s21_admin' -or $sql.port -ne 55449 -or $sql.in_recovery -ne $false -or !([IO.Path]::GetFullPath([string]$sql.data_directory)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'complexity_recovery_actual_sql_identity'}
 Bounds;Identity $server;$success=$true
}catch{
 $primary=$_;try{Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{exception_type=$primary.Exception.GetType().FullName;message=$primary.Exception.Message;position=$primary.InvocationInfo.PositionMessage;script_stack_trace=$primary.ScriptStackTrace;utc=[DateTimeOffset]::UtcNow.ToString('o')}}catch{Write-Warning ('complexity_recovery_failure_receipt_diagnostic: '+$_.Exception.Message)};throw $primary
}finally{
 try{
  if($server -and !$closed){
   if(!$server.Process.HasExited){Identity $server;[void](Invoke-OwnedPhaseCommand $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') $c.workspace $c.output 'pg-stop' @{} 20 2MB)}
   if(!$server.Process.WaitForExit(10000)){throw 'complexity_recovery_stop_timeout'}
   $record=Complete-Checked $server $true;$closed=$true
   if(Test-Path -LiteralPath $pidPath){throw 'complexity_recovery_postgres_did_not_remove_own_pidfile'}
  }
 }catch{
  $cleanup=$_;try{$job.Stop();if($server -and !$closed -and $server.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $server);$closed=$true}}catch{Write-Warning ('complexity_recovery_owned_cleanup_diagnostic: '+$_.Exception.Message)};throw $cleanup
 }finally{$job.Dispose()}
}
if($success){
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 Assert-OwnedHash $c.retained_start_path $c.retained_start_sha;Assert-OwnedHash (Join-Path $oldRoot 'postgres.stdout') $c.retained_stdout_sha;Assert-OwnedHash (Join-Path $oldRoot 'postgres.stderr') $c.retained_stderr_sha;Assert-OwnedHash $ownerPath $c.retained_owner_process_sha;Assert-OwnedHash $pidCopy $c.pid_file_sha
 Write-OwnedJson (Join-Path $c.output 'recovery-proof.json') @{status='ACTUAL_POSTGRES_OWN_STALE_PID_HANDLING_READY_SQL_AND_CLEAN_STOP';old_postgres_native_exit='UNKNOWN';old_postgres_stream_eof='UNKNOWN';prior_complexity_stage_whole_status='FAILED_INCOMPLETE';new_postgres_native_exit=$record.native_exit;new_postgres_full_streams_eof=$true;pg_isready_native_exit=0;readonly_sql_in_recovery=$false;postgres_removed_own_pidfile=$true;manual_pid_or_data_edit_used=$false;server_left_running=$false;config_sha256=$PhaseConfigSha}
}
