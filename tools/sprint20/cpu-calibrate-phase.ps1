param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'measured-runtime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'process-times.psm1') -Force
$out=New-OwnedPrivateDirectory $c.calibration_output
$nonce=[Guid]::NewGuid().ToString('N');$job=[PiS20MeasuredJob]::new();$child=$null;$completed=$false
$timer=[Diagnostics.Stopwatch]::StartNew()
function Wait-CalibrationFile([string]$Name){
 $path=Join-Path $out ($Name+'.json')
 while(!(Test-Path -LiteralPath $path)){
  if($timer.Elapsed.TotalSeconds -gt 30 -or $child.Process.HasExited -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){throw 'cpu_calibration_wait'}
  Start-Sleep -Milliseconds 20
 }
 if((Get-Item -LiteralPath $path).Length -gt 4096){throw 'cpu_calibration_file_cap'}
 $r=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
 if($r.pid -ne $child.Process.Id -or $r.nonce -cne $nonce){throw 'cpu_calibration_identity'}
 return $r
}
try{
 $invalid=$false
 try{[void][PiS20ProcessTimes]::Read([IntPtr]::Zero)}catch{$invalid=$_.Exception.ToString().Contains('process_times:')}
 if(!$invalid){throw 'cpu_invalid_handle_not_refused'}
 $child=Start-OwnedCapturedProcess -Program $c.python -ProgramSha256 $c.python_sha -Arguments @('-I','-B',$c.calibration_worker,$out,$nonce) -WorkingDirectory $c.workspace -OutputDirectory $out -Label cpu-control -MaxOutputBytes 1MB -RedirectInput $true
 $job.Assign($child.Handle)
 $boot=Wait-CalibrationFile 'boot'
 $baseline=Get-S20ProcessTimes $child.Handle
 $created=[DateTime]::FromFileTimeUtc([long]$baseline.creation_filetime_100ns).ToString('o')
 if($created -cne $child.Record.native_creation_utc -or $null -ne $baseline.exit_filetime_100ns){throw 'cpu_creation_or_live_exit'}
 $child.Process.StandardInput.WriteLine('GO '+$nonce);$child.Process.StandardInput.Flush()
 $ready=Wait-CalibrationFile 'ready'
 $live=Get-S20ProcessTimes $child.Handle
 $delta=([long]$live.user_cpu_100ns+[long]$live.kernel_cpu_100ns)-([long]$baseline.user_cpu_100ns+[long]$baseline.kernel_cpu_100ns)
 if($delta -lt 100000 -or $live.creation_filetime_100ns -ne $baseline.creation_filetime_100ns){throw 'cpu_positive_control'}
 Write-OwnedJson (Join-Path $out 'live-cpu.json') @{baseline=$baseline;terminal=$live;cpu_increase_100ns=$delta;boot=$boot;ready=$ready;native_creation_utc=$created;invalid_handle_refused=$invalid;scope='150ms controlled busy loop plus allocation; positive CPU response >=10ms, no exact scheduling expectation.'}
 $child.Process.StandardInput.WriteLine('EXIT '+$nonce);$child.Process.StandardInput.Close()
 if(!$child.Process.WaitForExit(10000)){throw 'cpu_exit_timeout'}
 $after=Get-S20ProcessTimes $child.Handle $true
 $jobAfter=Get-S20MeasuredJobSnapshot $job
 if($after.exit_filetime_100ns -le $after.creation_filetime_100ns -or $after.user_cpu_100ns -lt $live.user_cpu_100ns -or $after.kernel_cpu_100ns -lt $live.kernel_cpu_100ns -or $jobAfter.active_processes -ne 0){throw 'cpu_post_exit_retention'}
 $record=Complete-OwnedCapturedProcess $child;$completed=$true
 if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or $record.output_limit -or $record.capture_fault -or $record.drain_timeout){throw 'cpu_native_failure'}
 Write-OwnedJson (Join-Path $out 'calibration.json') @{status='PASS';config_sha256=$PhaseConfigSha;native=$record;after_exit=$after;job_after=$jobAfter;live_cpu_sha256=Get-OwnedHash (Join-Path $out 'live-cpu.json');claim='Native process creation identity, live CPU positive response, failure refusal and post-exit retained CPU; not miner or engine-only CPU.'}
}catch{
 $failure=$_
 if($child -and !$completed){try{$job.Stop();if($child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning $_.Exception.Message}}
 throw $failure
}finally{$job.Dispose()}
