param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# PostgreSQL owns stale-PID handling and WAL recovery. This observer never edits
# or removes postmaster.pid, database files or historical failure evidence.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'recovery_config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'process-identity.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$root=Join-Path $c.workspace '.local/sprint21/root'
$oldRoot=Join-Path $root 'historical01'
if($c.pgdata -cne (Join-Path $root 'pgdata06') -or $c.output -cne (Join-Path $root 'postgres-recovery01') -or $c.pg_port -ne 55446 -or $c.retained_process_path -cne (Join-Path $oldRoot 'postgres.process.json') -or $c.retained_start_path -cne (Join-Path $oldRoot 'postgres.start.json')){throw 'recovery_exact_scope'}
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata
Assert-OwnedHash $c.retained_process_path $c.retained_process_sha
Assert-OwnedHash $c.retained_start_path $c.retained_start_sha
$old=Get-Content -LiteralPath $c.retained_process_path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$start=Get-Content -LiteralPath $c.retained_start_path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$oldCreation='2026-10-22T19:13:27.2517728Z'
if($old.pid -ne 26968 -or $start.pid -ne 26968 -or $old.native_creation_utc -cne $oldCreation -or $start.native_creation_utc -cne $oldCreation -or $old.native_exit -ne 1 -or !$old.stdout_complete -or !$old.stderr_complete -or $old.output_limit -or $old.capture_fault -or $old.drain_timeout){throw 'recovery_retained_native_failure_contract'}
foreach($record in @($old,$start)){
 if(!([IO.Path]::GetFullPath([string]$record.program)).Equals([IO.Path]::GetFullPath([string]$c.postgres),[StringComparison]::OrdinalIgnoreCase) -or $record.program_sha256 -cne $c.postgres_sha){throw 'recovery_retained_image_pin'}
}
foreach($stream in @(@('stdout',$old.stdout_sha256,$old.stdout_bytes_persisted),@('stderr',$old.stderr_sha256,$old.stderr_bytes_persisted))){
 $path=Join-Path $oldRoot ('postgres.'+$stream[0]);Assert-OwnedHash $path $stream[1]
 if((Get-Item -LiteralPath $path).Length -ne $stream[2]){throw 'recovery_retained_stream_length'}
}
$pidPath=Join-Path $c.pgdata 'postmaster.pid'
foreach($pin in $c.pins){if(([IO.Path]::GetFullPath([string]$pin.path)).Equals([IO.Path]::GetFullPath($pidPath),[StringComparison]::OrdinalIgnoreCase)){throw 'recovery_mutable_pidfile_must_not_be_immutable_pin'}}
Assert-OwnedHash $pidPath $c.pid_file_sha
$pidLines=[IO.File]::ReadAllLines($pidPath)
$epoch=[DateTimeOffset]::ParseExact($oldCreation,'o',[Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
if($pidLines.Length -ne 8 -or $pidLines[0] -cne '26968' -or !([IO.Path]::GetFullPath($pidLines[1])).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase) -or $pidLines[2] -cne [string]$epoch -or $pidLines[3] -cne '55446' -or $pidLines[4] -cne '' -or $pidLines[5] -cne '127.0.0.1' -or $pidLines[6] -cne '' -or $pidLines[7].Trim() -cne 'ready'){throw 'recovery_stale_pidfile_contract'}
$retainedPid=Join-Path $c.output 'original-postmaster.pid.txt'
[IO.File]::Copy($pidPath,$retainedPid,$false)
Assert-OwnedHash $retainedPid $c.pid_file_sha
function Assert-OldPidAbsent {
 $observed=$null
 try{$observed=[Diagnostics.Process]::GetProcessById(26968)}catch{
  if($_.Exception.GetBaseException() -isnot [ArgumentException]){throw}
 }
 if($observed){$observed.Dispose();throw 'recovery_old_pid_present_or_reused'}
}
Assert-OldPidAbsent
$rows=@(Get-CimInstance Win32_Process -Filter "Name='postgres.exe'")
if($rows.Count -gt 128){throw 'recovery_cim_process_cap'}
$examined=0
foreach($row in $rows){
 if(!$row.CommandLine -or !$row.ExecutablePath){throw 'recovery_cim_opaque_postgres'}
 $argv=[PiWindowsArguments]::Parse([string]$row.CommandLine)
 for($index=1;$index -lt $argv.Length;$index++){
  $arg=$argv[$index];$dir=$null
  if($arg -ceq '-D' -or $arg -ceq '--pgdata'){if($index+1 -ge $argv.Length){throw 'recovery_cim_malformed_datadir'};$dir=$argv[++$index]}
  elseif($arg.StartsWith('-D',[StringComparison]::Ordinal) -and $arg.Length -gt 2){$dir=$arg.Substring(2)}
  elseif($arg.StartsWith('--pgdata=',[StringComparison]::Ordinal)){$dir=$arg.Substring(9)}
  if($null -ne $dir){
   if(!$dir -or ![IO.Path]::IsPathFullyQualified($dir)){throw 'recovery_cim_relative_or_empty_datadir'}
   if(([IO.Path]::GetFullPath($dir)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'recovery_same_datadir_postgres_present'}
  }
 }
 $examined++
}
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,[int]$c.pg_port)
try{$probe.Start()}finally{$probe.Stop()}
Write-OwnedJson (Join-Path $c.output 'recovery-preflight.json') @{status='OBSERVED_STALE_OWNED_PIDFILE_WITH_NO_OLD_PROCESS';old_pid=26968;old_creation_utc=$oldCreation;old_native_exit=1;old_full_streams_eof=$true;old_pid_absent=$true;postgres_cim_rows_examined=$examined;no_same_datadir_argument_observed=$true;port=$c.pg_port;port_available=$true;pid_file_sha256=$c.pid_file_sha;pid_file_start_epoch=$epoch;manual_pid_or_data_edit_used=$false;utc=[DateTimeOffset]::UtcNow.ToString('o')}
$deadline=[DateTimeOffset]$c.phase_deadline_utc
function Bounds {if([DateTimeOffset]::UtcNow -ge $deadline -or (Get-PSDrive C).Free -lt 8GB){throw 'recovery_deadline_or_free_floor'}}
$server=$null;$serverClosed=$false;$job=[PiOwnedJob]::new();$success=$false;$mainFailure=$null
function Identity($Child){
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Child.Process.Id)
 Assert-S21ProcessIdentity $Child $c.postgres $row $c.pgdata
}
function Complete-Checked($Child,[bool]$Zero){
 $r=Complete-OwnedCapturedProcess $Child
 if(($Zero -and $r.native_exit -ne 0) -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'recovery_native_exit_or_capture'}
 return $r
}
try{
 Bounds;Assert-OldPidAbsent;Assert-OwnedHash $pidPath $c.pid_file_sha
 $server=Start-OwnedCapturedProcess -Program $c.postgres -ProgramSha256 $c.postgres_sha -Arguments @('-D',$c.pgdata,'-h','127.0.0.1','-p',[string]$c.pg_port,'-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'postgres-recovery' -MaxOutputBytes 8MB
 $job.Assign($server.Handle);if(!$job.Member($server.Handle)){throw 'recovery_new_own_job'}
 $ready=$false;$until=[DateTimeOffset]::UtcNow.AddSeconds(20)
 while([DateTimeOffset]::UtcNow -lt $until){
  Bounds
  if($server.Process.HasExited){throw 'recovery_postgres_early_exit'}
  if($server.OutCapture.LimitReached -or $server.ErrCapture.LimitReached -or $server.OutCapture.Pump.IsFaulted -or $server.ErrCapture.Pump.IsFaulted){throw 'recovery_server_capture_fault'}
  $tcp=[Net.Sockets.TcpClient]::new()
  try{$task=$tcp.ConnectAsync('127.0.0.1',[int]$c.pg_port);if($task.Wait(200) -and $tcp.Connected){$ready=$true;break}}catch{
   $cause=$_.Exception.GetBaseException();if($cause -isnot [Net.Sockets.SocketException] -or $cause.SocketErrorCode -ne [Net.Sockets.SocketError]::ConnectionRefused){throw}
  }finally{$tcp.Dispose()}
  Start-Sleep -Milliseconds 50
 }
 if(!$ready){throw 'recovery_twenty_second_readiness_timeout'}
 Identity $server
 [void](Invoke-OwnedPhaseCommand $c.psql $c.psql_sha @('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_s21_admin','-w','-d','postgres','-c',"SELECT json_build_object('in_recovery',pg_is_in_recovery(),'data_directory',current_setting('data_directory'),'database',current_database(),'user',current_user,'port',inet_server_port())") $c.workspace $c.output 'sql-recovery-readonly' @{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c default_transaction_read_only=on';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8'} 10 1MB)
 $sql=Get-Content -LiteralPath (Join-Path $c.output 'sql-recovery-readonly.stdout') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($sql.in_recovery -ne $false -or $sql.database -cne 'postgres' -or $sql.user -cne 'pi_s21_admin' -or $sql.port -ne $c.pg_port -or !([IO.Path]::GetFullPath([string]$sql.data_directory)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'recovery_sql_cluster_identity_or_not_recovered'}
 Bounds;Identity $server
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $success=$true
}catch{
 $mainFailure=$_
 try{Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{status='ACTUAL_RECOVERY_FAILURE';message=$mainFailure.Exception.Message;exception_type=$mainFailure.Exception.GetType().FullName;position=$mainFailure.InvocationInfo.PositionMessage;script_stack_trace=$mainFailure.ScriptStackTrace;utc=[DateTimeOffset]::UtcNow.ToString('o')}}catch{Write-Warning ('recovery_failure_receipt_diagnostic: '+$_.Exception.Message)}
 throw $mainFailure
}finally{
 try{
  if($server -and !$serverClosed){
   if(!$server.Process.HasExited){Identity $server;[void](Invoke-OwnedPhaseCommand $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') $c.workspace $c.output 'pg-stop' @{} 20 2MB)}
   if(!$server.Process.WaitForExit(10000)){throw 'recovery_pg_stop_timeout'}
   $closed=Complete-Checked $server $true;$serverClosed=$true
   if(Test-Path -LiteralPath $pidPath){throw 'recovery_pidfile_not_removed_by_postgres'}
  }
 }catch{
  $cleanupFailure=$_
  try{$job.Stop();if($server -and !$serverClosed -and $server.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $server);$serverClosed=$true}}catch{Write-Warning ('recovery_owned_fallback_diagnostic: '+$_.Exception.Message)}
  throw $cleanupFailure
 }finally{$job.Dispose()}
}
if($success){
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 Assert-OwnedHash $c.retained_process_path $c.retained_process_sha;Assert-OwnedHash $c.retained_start_path $c.retained_start_sha
 foreach($stream in @(@('stdout',$old.stdout_sha256),@('stderr',$old.stderr_sha256))){Assert-OwnedHash (Join-Path $oldRoot ('postgres.'+$stream[0])) $stream[1]}
 Write-OwnedJson (Join-Path $c.output 'recovery-proof.json') @{status='ACTUAL_POSTGRES_OWN_STALE_PID_AND_WAL_RECOVERY';retained_exit=1;retained_full_streams_eof=$true;new_server_native_exit=$closed.native_exit;new_server_full_streams_eof=$true;read_only_sql_in_recovery=$false;postgres_removed_own_pidfile=$true;manual_pid_or_data_edit_used=$false;server_left_running=$false;config_sha256=$PhaseConfigSha;utc=[DateTimeOffset]::UtcNow.ToString('o')}
}
