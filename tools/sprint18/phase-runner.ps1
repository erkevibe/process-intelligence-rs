param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ws=[string]$PWD
Import-Module (Join-Path $ws 'tools/sprint18/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ws 'tools/sprint15/evidence-storage.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-guard.psm1') -Force
if((Get-FileHash $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$phaseDeadline=[DateTimeOffset]'2026-10-21T22:55:42Z'
if($c.ContainsKey('phase_deadline_utc')){
 $requestedDeadline=[DateTimeOffset]::ParseExact([string]$c.phase_deadline_utc,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
 if($requestedDeadline -gt $phaseDeadline){throw 'deadline_extension_refused'}
 $phaseDeadline=$requestedDeadline
}
if([DateTimeOffset]::UtcNow -ge $phaseDeadline){throw 'phase_deadline_expired'}
function Assert-S18Capacity {
 $why=''
 if([DateTimeOffset]::UtcNow -ge $phaseDeadline){throw 'runtime_freeze'}
 if((Get-PSDrive C).Free -lt 8GB){throw 'free_floor'}
 $sample=Get-S18ResourceSnapshot (Join-Path $ws '.local/sprint18') (Join-Path $ws '.local/sprint18/root/target')
 if($sample.root_logical_bytes -gt (8GB-512MB) -or $sample.logical_bytes -gt (12GB-512MB)){$why='capacity_headroom_stop'}
 if($sample.root_allocation_bytes -gt (8GB-512MB) -or $sample.allocation_bytes -gt (12GB-512MB)){$why='allocated_capacity_headroom_stop'}
 if($why){throw $why}
}
Assert-S18Capacity
$out=New-OwnedPrivateDirectory $c.output
$nonce=[Guid]::NewGuid().ToString('N');$job=[PiOwnedJob]::new();$child=$null;$why='';$captureCompleted=$false;$started=[DateTimeOffset]::UtcNow
try{
 $worker=Join-Path $ws 'tools/sprint18/phase-worker.ps1'
 $child=Start-OwnedCapturedProcess -Program $c.pwsh -ProgramSha256 $c.pwsh_sha -Arguments @('-NoProfile','-File',$worker,'-Config',$Config,'-ConfigSha',$ConfigSha,'-Nonce',$nonce) -WorkingDirectory $ws -OutputDirectory $out -Label command -MaxOutputBytes 8MB -RedirectInput $true
 $job.Assign($child.Handle);if(!$job.Member($child.Handle)){throw 'own_job'}
 Assert-S18Capacity
 $child.Process.StandardInput.WriteLine('GO '+$nonce);$child.Process.StandardInput.Close()
 $nextMeasure=[DateTimeOffset]::UtcNow
 while(!$child.Process.HasExited){
  if(([DateTimeOffset]::UtcNow-$started).TotalMinutes -gt 30){$why='timeout'}
  if([DateTimeOffset]::UtcNow -ge $phaseDeadline){$why='freeze'}
  if((Get-PSDrive C).Free -lt 8GB){$why='free_floor'}
  if($child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){$why='output_or_capture_fault'}
  if([DateTimeOffset]::UtcNow -ge $nextMeasure){
   Assert-S18Capacity
   $nextMeasure=[DateTimeOffset]::UtcNow.AddSeconds(20)
  }
  if($why){$job.Stop();if(!$child.Process.WaitForExit(10000)){throw 'owned_stop_timeout'};break}
  Start-Sleep -Milliseconds 500
 }
 $record=Complete-OwnedCapturedProcess $child; $captureCompleted=$true
 if($why -or $record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or $record.output_limit -or $record.capture_fault -or $record.drain_timeout){throw ('build_failed_'+$why)}
 Assert-S18Capacity
 Write-OwnedJson (Join-Path $out 'result.json') @{status='COMPLETED';effective_deadline_utc=$phaseDeadline.ToUniversalTime().ToString('o');native_exit=$record.native_exit;config_sha256=$ConfigSha;utc=[DateTimeOffset]::UtcNow.ToString('o');guard='new ownroot8GiB/S18total12GiB with512MiB padding, periodic20s logical+native allocation guard/free8; candidate final nativeallocation separate';all_output_eof=$true;exact_own_job=$true}
}catch{$failure=$_; if($child -and !$captureCompleted){try{$job.Stop(); if($child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning ('owned_cleanup_diagnostic: '+$_.Exception.Message)}};throw $failure}finally{$job.Dispose()}
