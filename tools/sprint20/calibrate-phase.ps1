param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'calibration_config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'calibration_input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'measured-runtime.psm1') -Force
$out=New-OwnedPrivateDirectory $c.calibration_output
$nonce=[Guid]::NewGuid().ToString('N');$job=[PiS20MeasuredJob]::new();$child=$null;$completed=$false
$timer=[Diagnostics.Stopwatch]::StartNew()
try{
 $invalidRefused=$false
 try{[void][PiS20MeasuredJob]::ProcessMemory([IntPtr]::Zero)}catch{$invalidRefused=$_.Exception.ToString().Contains('measured_process_memory:')}
 if(!$invalidRefused){throw 'invalid_handle_not_refused'}
 $child=Start-OwnedCapturedProcess -Program $c.python -ProgramSha256 $c.python_sha -Arguments @('-I','-B',$c.calibration_worker,$out,$nonce) -WorkingDirectory $c.workspace -OutputDirectory $out -Label allocation -MaxOutputBytes 1MB -RedirectInput $true
 $job.Assign($child.Handle)
 $bootPath=Join-Path $out 'boot.json'
 while(!(Test-Path -LiteralPath $bootPath)){
  if($timer.Elapsed.TotalSeconds -gt 30 -or $child.Process.HasExited -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){throw 'calibration_boot_failed'}
  Start-Sleep -Milliseconds 20
 }
 if((Get-Item -LiteralPath $bootPath).Length -gt 4096){throw 'calibration_boot_cap'}
 $boot=Get-Content -LiteralPath $bootPath -Raw|ConvertFrom-Json -AsHashtable
 if($boot.pid -ne $child.Process.Id -or $boot.nonce -cne $nonce){throw 'calibration_boot_identity'}
 $baseline=Get-S20MeasuredProcessMemory $child.Handle
 $before=Get-S20MeasuredJobSnapshot $job
 $go=$timer.ElapsedTicks
 $child.Process.StandardInput.WriteLine('GO '+$nonce);$child.Process.StandardInput.Flush()
 $readyPath=Join-Path $out 'ready.json'
 while(!(Test-Path -LiteralPath $readyPath)){
  if($timer.Elapsed.TotalSeconds -gt 30 -or $child.Process.HasExited -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){throw 'calibration_ready_failed'}
  Start-Sleep -Milliseconds 20
 }
 $readyTicks=$timer.ElapsedTicks
 if((Get-Item -LiteralPath $readyPath).Length -gt 4096){throw 'calibration_ready_cap'}
 $ready=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json -AsHashtable
 if($ready.pid -ne $child.Process.Id -or $ready.nonce -cne $nonce -or $ready.allocated_bytes -ne 32MB -or $ready.touched_pages -ne 8192){throw 'calibration_ready_identity'}
 $terminal=Get-S20MeasuredProcessMemory $child.Handle
 $live=Get-S20MeasuredJobSnapshot $job
 $commitIncrease=[long]$terminal.current_private_commit_bytes-[long]$baseline.current_private_commit_bytes
 if($commitIncrease -lt 24MB){throw 'calibration_allocation_response'}
 if($terminal.peak_working_set_bytes -lt 32MB -or $terminal.current_private_commit_bytes -lt 32MB -or $live.peak_job_commit_bytes -lt 32MB -or $live.total_processes -ne 1 -or $live.active_processes -ne 1){throw 'calibration_counter_lower_bound'}
 Write-OwnedJson (Join-Path $out 'live-counters.json') @{baseline=$baseline;job_before=$before;terminal=$terminal;job_live=$live;boot=$boot;ready=$ready;observed_current_private_commit_increase_bytes=$commitIncrease;pid=$child.Record.pid;creation_utc=$child.Record.native_creation_utc;invalid_handle_refused=$invalidRefused;stopwatch_frequency=[Diagnostics.Stopwatch]::Frequency;go_ticks=$go;ready_ticks=$readyTicks}
 $exitTicks=$timer.ElapsedTicks
 $child.Process.StandardInput.WriteLine('EXIT '+$nonce);$child.Process.StandardInput.Close()
 if(!$child.Process.WaitForExit(10000)){throw 'calibration_exit_timeout'}
 $after=Get-S20MeasuredJobSnapshot $job
 if($after.active_processes -ne 0 -or $after.total_processes -ne 1 -or $after.peak_job_commit_bytes -lt $live.peak_job_commit_bytes){throw 'calibration_job_retention'}
 $record=Complete-OwnedCapturedProcess $child;$completed=$true
 if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or $record.output_limit -or $record.capture_fault -or $record.drain_timeout){throw 'calibration_native_failure'}
 Write-OwnedJson (Join-Path $out 'calibration.json') @{status='PASS';config_sha256=$PhaseConfigSha;structure_sizes=[PiS20MeasuredJob]::StructureSizes();live_counters_sha256=Get-OwnedHash (Join-Path $out 'live-counters.json');job_after_exit=$after;native=$record;instrumented_lifetime_ticks=$timer.ElapsedTicks;exit_dispatch_ticks=$exitTicks;stopwatch_frequency=[Diagnostics.Stopwatch]::Frequency;claim='Known touched32MiB allocation lower bounds and retained Job accounting; no exact RAM expectation, no mining-engine timing, terminal process peaks exclude later teardown.'}
}catch{
 $failure=$_
 if($child -and !$completed){try{$job.Stop();if($child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning $_.Exception.Message}}
 throw $failure
}finally{$job.Dispose()}
