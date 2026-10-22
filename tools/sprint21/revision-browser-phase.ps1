param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'process-identity.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output
if($c.hold_seconds -lt 30 -or $c.hold_seconds -gt 1200){throw 'fixture_hold_bound'}
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,3134);try{$probe.Start()}finally{$probe.Stop()}
$until=[DateTimeOffset]::UtcNow.AddSeconds([int]$c.hold_seconds)
if($until -gt ([DateTimeOffset]$c.phase_deadline_utc).AddSeconds(-30)){throw 'fixture_freeze'}
$nonce=[Guid]::NewGuid().ToString('N');$child=$null;$closed=$false;$stopRequested=$false;$job=[PiOwnedJob]::new()
$http=[Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{UseProxy=$false;AllowAutoRedirect=$false});$http.Timeout=[TimeSpan]::FromSeconds(2)
try{
 $child=Start-OwnedCapturedProcess -Program $c.node -ProgramSha256 $c.node_sha -Arguments @((Join-Path $c.workspace 'tests/sprint21_revision_fixture.cjs'),$c.workspace) -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'fixture' -MaxOutputBytes 2MB -Environment @{S21_FIXTURE_STOP_NONCE=$nonce} -RedirectInput $true
 $job.Assign($child.Handle);if(!$job.Member($child.Handle)){throw 'fixture_job'}
 $ready=$false;$readyUntil=[DateTimeOffset]::UtcNow.AddSeconds(20)
 while([DateTimeOffset]::UtcNow -lt $readyUntil){
  if($child.Process.HasExited){throw 'fixture_early_exit'}
  $response=$null
  try{$response=$http.GetAsync('http://127.0.0.1:3134/').GetAwaiter().GetResult();if([int]$response.StatusCode -eq 200){$text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if($text.Length -gt 65536 -or !$text.Contains('revision-watcher')){throw 'fixture_wrong_document'};$ready=$true;break}}catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}finally{if($response){$response.Dispose()}}
  Start-Sleep -Milliseconds 100
 }
 if(!$ready){throw 'fixture_ready_timeout'}
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$child.Process.Id);Assert-S21ProcessIdentity $child $c.node $row
 Write-OwnedJson (Join-Path $c.output 'live-ready.json') @{ready=$true;nonce=$nonce;port=3134;deadline_utc=$until.ToUniversalTime().ToString('o');scope='Actual browser may exercise synthetic revision SSE using exact production assets; no conversion/auth/crash claim'}
 while([DateTimeOffset]::UtcNow -lt $until){
  if($child.Process.HasExited -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){throw 'fixture_exit_or_capture'}
  $stop=Join-Path $c.output 'stop-request.json'
  if(Test-Path -LiteralPath $stop){Assert-OwnedNoReparse $stop;if((Get-Item -LiteralPath $stop).Length -gt 4096){throw 'fixture_stop_capacity'};$request=Get-Content -LiteralPath $stop -Raw|ConvertFrom-Json -AsHashtable -DateKind String;if($request.Count -ne 1 -or $request.nonce -cne $nonce){throw 'fixture_stop_identity'};$stopRequested=$true;break}
  Start-Sleep -Milliseconds 200
 }
}finally{
 try{
  if($child){
   if(!$child.Process.HasExited){$row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$child.Process.Id);Assert-S21ProcessIdentity $child $c.node $row;$child.Process.StandardInput.WriteLine('STOP '+$nonce);$child.Process.StandardInput.Close()}
   if(!$child.Process.WaitForExit(10000)){throw 'fixture_shutdown_timeout'}
   $record=Complete-OwnedCapturedProcess $child;$closed=$true
   if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or $record.output_limit -or $record.capture_fault -or $record.drain_timeout){throw 'fixture_capture_or_exit'}
  }
 }catch{
  $failure=$_;try{$job.Stop();if($child -and !$closed -and $child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning ('fixture_cleanup_diagnostic: '+$_.Exception.Message)};throw $failure
 }finally{$job.Dispose();$http.Dispose()}
}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'fixture-closed.json') @{status='OWNED_REVISION_FIXTURE_CLOSED';native_exit=$record.native_exit;all_streams_eof=$true;stop_requested=$stopRequested;browser_acceptance_recorded_separately=$true}
