param(
 [Parameter(Mandatory)][string]$ConfigPath,
 [Parameter(Mandatory)][string]$ConfigSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$allowed=Join-Path $workspace '.local/sprint18/service'
$runtime=Join-Path $PSScriptRoot 'public-service-runtime.psm1'
if((Get-FileHash $runtime).Hash -cne '3FBB40AFB9B91F88BD1D1AA19B29BD695384CF63425EC9BE33E529304CFF7C0F'){throw 'owned_runtime_pin'}
if((Get-Item $ConfigPath).Length -gt 65536 -or (Get-FileHash $ConfigPath).Hash -cne $ConfigSha256){throw 'exact_config'}
$c=Get-Content $ConfigPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if(!$c.ContainsKey('worker_go') -or !$c.worker_go){throw 'mandatory_owned_worker_go'}
Import-Module $runtime -Force -DisableNameChecking
if($c.ContainsKey('runtime_manifest')){
 Assert-OwnedHash $c.runtime_manifest.path $c.runtime_manifest.sha256
 if((Get-Item -LiteralPath $c.runtime_manifest.path).Length -gt 4MB){throw 'bounded_runtime_manifest'}
 $runtimeManifest=Get-Content -LiteralPath $c.runtime_manifest.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($runtimeManifest.original_source_files -ne 5763 -or @($runtimeManifest.runtime_files).Count -ne 285){throw 'canonical_runtime_shape'}
 $c.pins=@($c.pins)+@($runtimeManifest.runtime_files)
}
$out=[IO.Path]::GetFullPath($c.output_directory)
$work=[IO.Path]::GetFullPath($c.working_directory)
if([IO.Path]::GetFullPath($c.cwd) -cne $work){throw 'worker_working_directory_identity'}
foreach($p in @($out,$work)){
 if(!$p.StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'private_service_scope'}
 if(Test-Path $p){Assert-OwnedNoReparse $p}else{Assert-OwnedNoReparse (Split-Path -Parent $p)}
}
if(Test-Path $out){throw 'new_attempt_output'}
if($c.timeout_seconds -lt 1 -or $c.timeout_seconds -gt 180 -or $c.max_output_bytes -lt 1024 -or $c.max_output_bytes -gt 8MB){throw 'bounded_config'}
$deadline=[DateTimeOffset]::Parse('2026-10-21T22:55:42Z').UtcDateTime
if([DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'deadline_or_disk_floor'}
foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256}
[void](New-OwnedPrivateDirectory $out)
Assert-OwnedPrivateDirectory $out
$job=[PiOwnedJob]::new();$child=$null;$record=$null;$reason=$null
$started=[DateTime]::UtcNow
try{
 if($c.ContainsKey('worker_go') -and $c.worker_go){
  $worker=Join-Path $PSScriptRoot 'public-service-worker.ps1'
  $pwsh=(Get-Process -Id $PID).Path
  Assert-OwnedHash $worker $c.worker_sha256
  Assert-OwnedHash $pwsh $c.pwsh_sha256
  if($c.module_sha256 -cne '3FBB40AFB9B91F88BD1D1AA19B29BD695384CF63425EC9BE33E529304CFF7C0F'){throw 'worker_runtime_pin'}
  $child=Start-OwnedCapturedProcess -Program $pwsh -ProgramSha256 $c.pwsh_sha256 -Arguments @('-NoProfile','-File',$worker,'-ConfigPath',[IO.Path]::GetFullPath($ConfigPath),'-ConfigSha256',$ConfigSha256) -WorkingDirectory $work -OutputDirectory $out -Label 'worker' -MaxOutputBytes $c.max_output_bytes -RedirectInput $true
 }
 $job.Assign($child.Handle)
 if(!$job.Member($child.Handle)){throw 'own_job_membership'}
 if($c.ContainsKey('worker_go') -and $c.worker_go){
  $child.Process.StandardInput.WriteLine('GO '+$ConfigSha256.ToUpperInvariant())
  $child.Process.StandardInput.Close()
 }
 $lastMeter=[DateTime]::MinValue;$observedMax=0L;$observedFiles=0
 while(!$child.Process.WaitForExit(100)){
  if(([DateTime]::UtcNow-$started).TotalSeconds -gt $c.timeout_seconds){$reason='timeout'}
  if([DateTime]::UtcNow -ge $deadline){$reason='sprint_freeze'}
  if([IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){$reason='disk_floor'}
  if($child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){$reason='capture_stop'}
  if(([DateTime]::UtcNow-$lastMeter).TotalSeconds -gt 10){
   $rows=@(Get-ChildItem -LiteralPath $allowed -Recurse -File -Force -ErrorAction Stop)
   if(@($rows|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'own_root_reparse'}
   $logical=0L;foreach($f in $rows){$logical+=$f.Length}
   # Explicit pessimistic padding, not a measurement of native allocation.
   # A separate closing native footprint is required for allocation acceptance.
   $upper=$logical+65536L*$rows.Count+256MB
   $observedMax=[Math]::Max($observedMax,$upper);$observedFiles=[Math]::Max($observedFiles,$rows.Count)
   if($upper -gt 2GB){$reason='service_space_upper'}
   $lastMeter=[DateTime]::UtcNow
  }
  if($reason){$job.Stop();if(!$child.Process.WaitForExit(10000)){throw 'own_job_stop_timeout'};break}
 }
 # Kill-on-close applies only to this unnamed job; no Gradle daemon is retained.
 $job.Dispose()
 $record=Complete-OwnedCapturedProcess $child
 $child=$null
 foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256}
 $proof=@{utc=[DateTime]::UtcNow.ToString('o');config_sha256=$ConfigSha256;native=$record;stop_reason=$reason;max_observed_service_logical_plus_padding=$observedMax;max_observed_file_count=$observedFiles;allocation_claim='No actual allocation measurement inferred from padding. Closing native measurement required.';free_after=[IO.DriveInfo]::new('C').AvailableFreeSpace;status=if(!$reason -and $record.native_exit -eq 0 -and $record.stdout_complete -and $record.stderr_complete -and !$record.output_limit -and !$record.capture_fault -and !$record.drain_timeout){'COMMAND_COMPLETED'}else{'COMMAND_FAILED_OR_STOPPED'}}
 Write-OwnedJson (Join-Path $out 'result.json') $proof
 $proof|ConvertTo-Json -Depth 8
 if($proof.status -cne 'COMMAND_COMPLETED'){exit 1}
}finally{
 $job.Dispose()
 if($child -and !$child.Process.HasExited){$child.Process.Kill($true);[void]$child.Process.WaitForExit(10000)}
 if($child -and $child.Process.HasExited){[void](Complete-OwnedCapturedProcess $child)}
}
