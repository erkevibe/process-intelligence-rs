param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# Finite private browser fixture. The browser and acceptance observer remain external.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $c.workspace 'tools/sprint21/process-identity.psm1') -Force
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $c.workspace 'tools/sprint21-capacity/postgres-readiness.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$root=Join-Path $c.workspace '.local/sprint21/root'
if($c.pgdata -cne (Join-Path $root 'pgdata11') -or $c.output -cne (Join-Path $root 'capacity-browser-stand02') -or $c.pg_port -ne 55449 -or $c.app_port -ne 3131 -or $c.database -cne 'pi_s21_browser'){throw 'browser_stand_scope'}
if($c.hold_seconds -lt 30 -or $c.hold_seconds -gt 1500){throw 'browser_stand_finite_hold'}
Assert-OwnedPrivateDirectory $c.pgdata;Assert-OwnedPrivateDirectory $c.output
Assert-OwnedHash $c.app $c.app_sha
if([IO.File]::ReadAllText((Join-Path $c.pgdata 'PG_VERSION')).Trim() -cne '18' -or (Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid'))){throw 'browser_stand_existing_cluster_not_stopped'}
foreach($port in @([int]$c.pg_port,[int]$c.app_port)){
 $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
 try{$probe.Start()}finally{$probe.Stop()}
}
$controls=New-OwnedPrivateDirectory (Join-Path $c.output 'controls')
$nonce=[Guid]::NewGuid().ToString('N');$started=[DateTimeOffset]::UtcNow
$deadline=[DateTimeOffset]$c.phase_deadline_utc
$until=$started.AddSeconds([int]$c.hold_seconds)
if($until -gt $deadline.AddSeconds(-30)){throw 'browser_stand_hold_beyond_freeze'}
$script:pg=$null;$script:pgClosed=$false;$script:app=$null;$script:appClosed=$true;$script:appStarts=0
$pgJob=[PiOwnedJob]::new();$script:appJob=$null;$commandSeq=0;$stopRequested=$false;$shutdownOkay=$false
$http=[Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{UseProxy=$false;AllowAutoRedirect=$false})
$http.Timeout=[TimeSpan]::FromSeconds(2)
function Check-Stand {
 if([DateTimeOffset]::UtcNow -ge $until -or [DateTimeOffset]::UtcNow -ge $deadline -or (Get-PSDrive C).Free -lt 8GB){throw 'browser_stand_expired_or_free_floor'}
 foreach($entry in @(@($script:pg,$script:pgClosed),@($script:app,$script:appClosed))){
  $child=$entry[0]
  if($child -and !$entry[1]){
   if($child.Process.HasExited){throw 'browser_stand_unexpected_process_exit'}
   if($child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){throw 'browser_stand_capture_fault'}
  }
 }
}
function Assert-Identity($Child,[string]$Expected,[bool]$IsPg=$false){
 if(!$Child -or $Child.Process.HasExited){throw 'browser_stand_owned_process_not_live'}
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Child.Process.Id)
 if(!$row -or !([IO.Path]::GetFullPath([string]$row.ExecutablePath)).Equals([IO.Path]::GetFullPath($Expected),[StringComparison]::OrdinalIgnoreCase)){throw 'browser_stand_image_identity'}
 Assert-S21ProcessIdentity $Child $Expected $row
 if($IsPg){[void](Get-OwnedDatadirArgument ([string]$row.CommandLine) $c.pgdata)}
}
function Complete-Checked($Child,[bool]$RequireZero){
 $record=Complete-OwnedCapturedProcess $Child
 if(($RequireZero -and $record.native_exit -ne 0) -or !$record.stdout_complete -or !$record.stderr_complete -or $record.output_limit -or $record.capture_fault -or $record.drain_timeout){throw 'browser_stand_exit_or_full_capture'}
 return $record
}
function Stop-App([string]$Reason){
 if($script:appClosed){throw 'browser_stand_app_already_stopped'}
 Assert-Identity $script:app $c.app
 $script:appJob.Stop()
 if(!$script:app.Process.WaitForExit(10000)){throw 'browser_stand_app_stop_timeout'}
 $r=Complete-Checked $script:app $false
 $script:appClosed=$true
 $script:appJob.Dispose();$script:appJob=$null
 Write-OwnedJson (Join-Path $c.output ('app-'+$script:appStarts+'-stop.json')) @{reason=$Reason;controlled_forced_stop=$true;clean_shutdown_not_claimed=$true;native_exit=$r.native_exit;native_creation_utc=$r.native_creation_utc;pid=$r.pid;full_streams_eof=$true}
}
function Start-App {
 if(!$script:appClosed -or $script:appStarts -ge 3){throw 'browser_stand_start_limit_or_already_running'}
 Check-Stand;Assert-Identity $script:pg $c.postgres $true
 $script:appStarts++
 $label='app-'+$script:appStarts
 $script:appJob=[PiOwnedJob]::new()
 $script:app=Start-OwnedCapturedProcess -Program $c.app -ProgramSha256 $c.app_sha -Arguments @() -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label $label -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL="host=127.0.0.1 port=$($c.pg_port) user=pi_s21_app dbname=$($c.database) connect_timeout=5 application_name=s21_browser";PORT=[string]$c.app_port;RUST_LOG='info'}
 $script:appClosed=$false
 $script:appJob.Assign($script:app.Handle)
 if(!$script:appJob.Member($script:app.Handle)){throw 'browser_stand_app_job'}
 $healthy=$false;$healthUntil=[DateTimeOffset]::UtcNow.AddSeconds(30)
 while([DateTimeOffset]::UtcNow -lt $healthUntil){
  Check-Stand
  $response=$null
  try{
   $response=$http.GetAsync('http://127.0.0.1:'+ $c.app_port +'/health').GetAwaiter().GetResult()
   if([int]$response.StatusCode -eq 200){$body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if($body.Length -gt 4096){throw 'browser_stand_health_size'};$healthy=$true;break}
  }catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}finally{if($response){$response.Dispose()}}
  Start-Sleep -Milliseconds 100
 }
 if(!$healthy){throw 'browser_stand_health_timeout'}
 Assert-Identity $script:app $c.app
 Write-OwnedJson (Join-Path $c.output ($label+'-ready.json')) @{app_start=$script:appStarts;pid=$script:app.Process.Id;native_creation_utc=$script:app.Record.native_creation_utc;app_sha256=$c.app_sha;health_status=200;health_body=$body;utc=[DateTimeOffset]::UtcNow.ToString('o')}
}
try{
 $script:pg=Start-OwnedCapturedProcess -Program $c.postgres -ProgramSha256 $c.postgres_sha -Arguments @('-D',$c.pgdata,'-h','127.0.0.1','-p',[string]$c.pg_port,'-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'postgres' -MaxOutputBytes 8MB
 $pgJob.Assign($script:pg.Handle)
 if(!$pgJob.Member($script:pg.Handle)){throw 'browser_stand_pg_job'}
 $tcpReady=$false;$pgUntil=[DateTimeOffset]::UtcNow.AddSeconds(30)
 while([DateTimeOffset]::UtcNow -lt $pgUntil){
  Check-Stand;$tcp=[Net.Sockets.TcpClient]::new()
  try{$connect=$tcp.ConnectAsync('127.0.0.1',[int]$c.pg_port);if($connect.Wait(250) -and $tcp.Connected){$tcpReady=$true;break}}catch{}finally{$tcp.Dispose()}
  Start-Sleep -Milliseconds 100
 }
 if(!$tcpReady){throw 'browser_stand_pg_tcp_timeout'}
 [void](Wait-S21PostgresReady $c $script:pg 20)
 Assert-Identity $script:pg $c.postgres $true
 [void](Invoke-OwnedPhaseCommand $c.psql $c.psql_sha @('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_s21_admin','-w','-d',$c.database,'-c',"SELECT current_setting('data_directory'),current_database(),current_user") $c.workspace $c.output 'sql-owned-cluster' @{PGCONNECT_TIMEOUT='5'} 15 1MB)
 $sql=[IO.File]::ReadAllText((Join-Path $c.output 'sql-owned-cluster.stdout')).Trim().Split('|')
 if($sql.Count -ne 3 -or !([IO.Path]::GetFullPath($sql[0])).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase) -or $sql[1] -cne $c.database -or $sql[2] -cne 'pi_s21_admin'){throw 'browser_stand_connected_cluster_identity'}
 Start-App
 Write-OwnedJson (Join-Path $c.output 'live-ready.json') @{nonce=$nonce;next_command_sequence=1;app_start=$script:appStarts;app_port=$c.app_port;postgres_port=$c.pg_port;database=$c.database;deadline_utc=$until.ToUniversalTime().ToString('o');controller_pid=$PID;ready=$true;acceptance_not_claimed=$true}
 while(!$stopRequested -and [DateTimeOffset]::UtcNow -lt $until){
  Check-Stand
  $next=$commandSeq+1;$name=('{0:D6}.json' -f $next);$path=Join-Path $controls $name
  $present=@(Get-ChildItem -LiteralPath $controls -File -Force)
  if($present.Count -gt 16){throw 'browser_stand_command_count'}
  foreach($entry in $present){if($entry.Name -notmatch '^\d{6}\.json$' -or $entry.Length -gt 16KB){throw 'browser_stand_command_shape'};Assert-OwnedNoReparse $entry.FullName}
  if(Test-Path -LiteralPath $path){
   $cmd=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
   if($cmd.Count -ne 3 -or !$cmd.ContainsKey('nonce') -or !$cmd.ContainsKey('sequence') -or !$cmd.ContainsKey('operation') -or $cmd.nonce -cne $nonce -or $cmd.sequence -isnot [long] -or $cmd.sequence -ne $next){throw 'browser_stand_command_identity'}
   $commandHash=Get-OwnedHash $path
   switch([string]$cmd.operation){
    'kill-app' {Stop-App 'requested_crash'}
    'start-app' {Start-App}
    'stop' {$stopRequested=$true}
    default {throw 'browser_stand_command_operation'}
   }
   Assert-OwnedHash $path $commandHash
   $commandSeq=$next
   Write-OwnedJson (Join-Path $c.output ('command-'+('{0:D6}' -f $commandSeq)+'-receipt.json')) @{sequence=$commandSeq;operation=$cmd.operation;command_sha256=$commandHash;app_starts=$script:appStarts;app_running=!$script:appClosed;utc=[DateTimeOffset]::UtcNow.ToString('o');status='COMPLETED'}
  }
  Start-Sleep -Milliseconds 250
 }
}catch{
 $mainFailure=$_
 try{Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{status='ACTUAL_MAIN_FAILURE';utc=[DateTimeOffset]::UtcNow.ToString('o');message=$mainFailure.Exception.Message;base_exception_type=$mainFailure.Exception.GetBaseException().GetType().FullName;position=$mainFailure.InvocationInfo.PositionMessage;script_stack_trace=$mainFailure.ScriptStackTrace;config_sha256=$PhaseConfigSha}}catch{Write-Warning ('browser_primary_failure_receipt_diagnostic: '+$_.Exception.Message)}
 throw $mainFailure
}finally{
 try{
  if($script:app -and !$script:appClosed){
   if($script:app.Process.HasExited){[void](Complete-Checked $script:app $false);$script:appClosed=$true;$script:appJob.Dispose();$script:appJob=$null}else{Stop-App 'fixture_shutdown'}
  }
  if($script:pg -and !$script:pgClosed){
   if(!$script:pg.Process.HasExited){Assert-Identity $script:pg $c.postgres $true;[void](Invoke-OwnedPhaseCommand $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') $c.workspace $c.output 'pg-stop' @{} 20 2MB)}
   if(!$script:pg.Process.WaitForExit(10000)){throw 'browser_stand_pg_stop_timeout'}
   [void](Complete-Checked $script:pg $true);$script:pgClosed=$true
  }
  $shutdownOkay=$true
 }catch{
  $shutdownError=$_
  try{if($script:appJob){$script:appJob.Stop()};$pgJob.Stop()}catch{Write-Warning ('browser_stand_owned_stop_diagnostic: '+$_.Exception.Message)}
  foreach($child in @($script:app,$script:pg)){try{if($child -and $child.Process -and $child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning ('browser_stand_capture_cleanup_diagnostic: '+$_.Exception.Message)}}
  throw $shutdownError
 }finally{if($script:appJob){$script:appJob.Dispose()};$pgJob.Dispose();$http.Dispose()}
}
if($shutdownOkay){Write-OwnedJson (Join-Path $c.output 'stand-closed.json') @{status='OWNED_BROWSER_FIXTURE_CLOSED';commands=$commandSeq;stop_requested=$stopRequested;app_starts=$script:appStarts;max_app_starts=3;all_processes_stopped=$true;full_streams_eof=$true;browser_acceptance_not_claimed=$true;utc=[DateTimeOffset]::UtcNow.ToString('o')}}
