param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ws=[string]$PWD
Import-Module (Join-Path $ws 'tools/sprint18/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ws 'tools/sprint15/evidence-storage.psm1') -Force -DisableNameChecking
if((Get-FileHash $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content $Config -Raw|ConvertFrom-Json -AsHashtable
function Assert-S18Capacity {
 $why=''
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]'2026-10-21T22:55:42Z'){throw 'runtime_freeze'}
 if((Get-PSDrive C).Free -lt 8GB){throw 'free_floor'}
   $rootBytes=(Get-ChildItem (Join-Path $ws '.local/sprint18/root') -Recurse -File -Force|Measure-Object Length -Sum).Sum
   $allBytes=(Get-ChildItem (Join-Path $ws '.local/sprint18') -Recurse -File -Force|Measure-Object Length -Sum).Sum
   if($rootBytes -gt (8GB-512MB) -or $allBytes -gt (12GB-512MB)){$why='capacity_headroom_stop'}
   [long]$allocated=0;[long]$rootAllocated=0
   foreach($file in Get-ChildItem (Join-Path $ws '.local/sprint18') -Recurse -File -Force){
    if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){$why='reparse_refused';break}
    try{$stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));try{$storage=[PiS13EvidenceStorageV1]::Inspect($stream)}finally{$stream.Dispose()}}catch{if(Test-Path -LiteralPath $file.FullName){throw};continue}
    $allocated+=$storage.AllocationSize
    if($file.FullName.StartsWith((Join-Path $ws '.local/sprint18/root')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){$rootAllocated+=$storage.AllocationSize}
   }
   if($rootAllocated -gt (8GB-512MB) -or $allocated -gt (12GB-512MB)){$why='allocated_capacity_headroom_stop'}
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
  if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]'2026-10-21T22:55:42Z'){$why='freeze'}
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
 Write-OwnedJson (Join-Path $out 'result.json') @{status='COMPLETED';native_exit=$record.native_exit;config_sha256=$ConfigSha;utc=[DateTimeOffset]::UtcNow.ToString('o');guard='new ownroot8GiB/S18total12GiB with512MiB padding, periodic20s logical+native allocation guard/free8; candidate final nativeallocation separate';all_output_eof=$true;exact_own_job=$true}
}catch{$failure=$_; if($child -and !$captureCompleted){try{$job.Stop(); if($child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning ('owned_cleanup_diagnostic: '+$_.Exception.Message)}};throw $failure}finally{$job.Dispose()}
