param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'miner-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'measured-runtime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'process-times.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'miner-environment.psm1') -Force
Assert-OwnedPrivateDirectory $c.output
$classpath=Assert-S20MinerEnvironment $c
$build=Get-Content -LiteralPath $c.build_proof -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($build.status -cne 'ACTUAL_OWN_HARNESS_COMPILED_NO_MINING_EXECUTION'){throw 'actual_java_build_required'}
foreach($row in $build.class_files){Assert-OwnedHash (Join-Path $build.classes $row.path) $row.sha256}
Write-S20MinerEnvironment $c $build $classpath
$manifest=Get-Content -LiteralPath $c.corpus -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($manifest.process_order.Count -ne 32 -or $manifest.required_call_count -ne 64 -or $manifest.optional_alphappp.enabled){throw 'frozen_schedule'}
$rows=[Collections.Generic.List[object]]::new()
$phaseStart=[DateTimeOffset]::UtcNow
$hardware=@{status='unavailable';observation_utc=[DateTimeOffset]::UtcNow.ToString('o')}
try{
 $os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop|Select-Object Caption,Version,BuildNumber,OSArchitecture,TotalVisibleMemorySize
 $processors=@(Get-CimInstance Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop|Select-Object Name,Manufacturer,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)
 $machine=Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop|Select-Object TotalPhysicalMemory,NumberOfLogicalProcessors
 $hardware=@{status='observed';observation_utc=[DateTimeOffset]::UtcNow.ToString('o');operating_system=$os;processors=$processors;machine_capacity=$machine;serials_hostnames_usernames_not_collected=$true;load_caveat='Basic capacity metadata only; no idle-host, fixed-frequency, affinity, or controlled OS-cache claim.'}
}catch{$hardware.reason=$_.Exception.Message}
Write-OwnedJson (Join-Path $c.output 'hardware.json') $hardware
function Rel([string]$Path){[IO.Path]::GetRelativePath($c.output,$Path).Replace('\','/')}
function Read-Protocol([string]$Path,[string]$Phase){
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{
  if($stream.Length -gt 8MB){throw 'protocol_stream_bound'}
  $bytes=[byte[]]::new([int]$stream.Length);$read=0
  while($read -lt $bytes.Length){$n=$stream.Read($bytes,$read,$bytes.Length-$read);if($n -eq 0){break};$read+=$n}
 }finally{$stream.Dispose()}
 # Decode only complete lines: a concurrently written final UTF-8 code point
 # may itself be partial. Invalid UTF-8 within a completed line still fails.
 $last=-1
 for($i=$read-1;$i -ge 0;$i--){if($bytes[$i] -eq 10){$last=$i;break}}
 if($last -lt 0){return $null}
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,0,$last+1)
 $lines=$text.Split([char]10)
 for($i=0;$i -lt $lines.Length-1;$i++){
  $line=$lines[$i].TrimEnd([char]13)
  if($line.StartsWith('S20_PROTOCOL ',[StringComparison]::Ordinal)){
   if($line.Length -gt 65536){throw 'protocol_line_bound'}
   $record=$line.Substring(13)|ConvertFrom-Json -AsHashtable -DateKind String
   if($record.phase -ceq $Phase){return $record}
  }
 }
 return $null
}
function Assert-Artifact([string]$Directory,[hashtable]$Descriptor,[long]$Cap){
 if($Descriptor.file -cnotmatch '^[A-Za-z0-9._-]+$'){throw 'artifact_name'}
 $path=Join-Path $Directory $Descriptor.file
 Assert-OwnedNoReparse $path
 $length=(Get-Item -LiteralPath $path).Length
 if($length -ne $Descriptor.bytes -or $length -gt $Cap){throw 'artifact_size'}
 Assert-OwnedHash $path $Descriptor.sha256.ToUpperInvariant()
}
foreach($scheduled in $manifest.process_order){
 if($scheduled.process_id -cnotmatch '^[a-z][a-z0-9-]{0,63}$'){throw 'trial_id'}
 $seconds=[int]$scheduled.timeout_seconds
 if($seconds -notin @(60,180) -or [DateTimeOffset]::UtcNow.AddSeconds($seconds+30) -ge [DateTimeOffset]$c.phase_deadline_utc -or ([DateTimeOffset]::UtcNow-$phaseStart).TotalSeconds -gt 3600){throw 'trial_start_deadline'}
 $case=@($manifest.cases|Where-Object{$_.id -ceq $scheduled.case_id})
 if($case.Count -ne 1 -or $case[0].file -cnotmatch '^[a-z0-9-]+\.xes$'){throw 'trial_case'}
 $inputPath=Join-Path (Split-Path -Parent $c.corpus) $case[0].file
 Assert-OwnedHash $inputPath $case[0].sha256.ToUpperInvariant()
 $trial=New-OwnedPrivateDirectory (Join-Path $c.output $scheduled.process_id)
 $environment=New-S20JavaEnvironment $trial
 $capture=New-OwnedPrivateDirectory (Join-Path $trial 'capture')
 $resultDir=Join-Path $trial 'results'
 $nonce=[Guid]::NewGuid().ToString('N')
 $regime=if($scheduled.regime -ceq 'cold-fresh-jvm'){'cold'}else{'warm'}
 $arguments=(Get-S20JvmArgs $trial)+@('-classpath',($build.classes+';'+$classpath),'SplitMinerBenchmarkHarness',$inputPath,$resultDir,$scheduled.process_id,$scheduled.case_id,$nonce,$regime)
 $argfile=Join-Path $trial 'java.args';Write-S20JavaArgs $argfile $arguments
 $job=[PiS20MeasuredJob]::new();$child=$null;$completed=$false;$failureCode=$null;$terminal=$null;$live=$null;$native=$null;$after=$null;$jobAfter=$null
 $timer=[Diagnostics.Stopwatch]::StartNew();$bootTicks=$null;$goTicks=$null;$terminalTicks=$null;$exitTicks=$null;$observedExitTicks=$null
 try{
  $child=Start-OwnedCapturedProcess -Program $c.java -ProgramSha256 $c.java_sha -Arguments @('@'+$argfile) -WorkingDirectory (Join-Path $trial 'cwd') -OutputDirectory $capture -Label benchmark -MaxOutputBytes 8MB -RedirectInput $true -Environment $environment
  # The outer worker already belongs to its Job before GO; every descendant is
  # owned from creation. This fresh nested trial Job starts at assignment.
  $job.Assign($child.Handle)
  foreach($phase in @('BOOT_READY','TERMINAL_READY')){
   $protocol=$null
   while($null -eq $protocol){
    if($timer.Elapsed.TotalSeconds -gt $seconds -or $child.Process.HasExited -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){throw ('trial_wait_'+$phase)}
    $protocol=Read-Protocol ($child.Base+'.stdout') $phase
    if($null -eq $protocol){Start-Sleep -Milliseconds 20}
   }
   if($protocol.pid -ne $child.Process.Id -or $protocol.nonce -cne $nonce -or $protocol.process_id -cne $scheduled.process_id){throw 'trial_protocol_identity'}
   if($phase -ceq 'BOOT_READY'){
    $bootTicks=$timer.ElapsedTicks
    $baselineMemory=Get-S20MeasuredProcessMemory $child.Handle
    $baselineCPU=Get-S20ProcessTimes $child.Handle
    if([DateTime]::FromFileTimeUtc([long]$baselineCPU.creation_filetime_100ns).ToString('o') -cne $child.Record.native_creation_utc){throw 'trial_creation_identity'}
    Write-OwnedJson (Join-Path $trial 'boot-counters.json') @{process_memory=$baselineMemory;process_cpu=$baselineCPU;job=(Get-S20MeasuredJobSnapshot $job);protocol=$protocol;native_creation_utc=$child.Record.native_creation_utc}
    $goTicks=$timer.ElapsedTicks;$child.Process.StandardInput.WriteLine('GO '+$nonce);$child.Process.StandardInput.Flush()
   }else{$terminal=$protocol;$terminalTicks=$timer.ElapsedTicks}
  }
  Assert-Artifact $resultDir $terminal.terminal_ready 65536
  Assert-Artifact $resultDir $terminal.summary 8MB
  Assert-Artifact $resultDir $terminal.ledger 1MB
  $summary=Get-Content -LiteralPath (Join-Path $resultDir $terminal.summary.file) -Raw|ConvertFrom-Json -AsHashtable -DateKind String
  if($terminal.scheduled_calls -ne $scheduled.iterations.Count -or $terminal.completed_calls -ne $scheduled.iterations.Count -or $summary.iterations.Count -ne $scheduled.iterations.Count){throw 'trial_call_count'}
  foreach($artifact in $summary.artifacts){Assert-Artifact $resultDir $artifact 1MB}
  $live=@{process_memory=Get-S20MeasuredProcessMemory $child.Handle;process_cpu=Get-S20ProcessTimes $child.Handle;job=Get-S20MeasuredJobSnapshot $job;terminal=$terminal;native_creation_utc=$child.Record.native_creation_utc;stopwatch_frequency=[Diagnostics.Stopwatch]::Frequency;boot_ready_ticks=$bootTicks;go_dispatch_ticks=$goTicks;terminal_ready_ticks=$terminalTicks}
  Write-OwnedJson (Join-Path $trial 'live-counters.json') $live
  if(($timer.ElapsedTicks-$terminalTicks)/[double][Diagnostics.Stopwatch]::Frequency -gt 10){throw 'terminal_measurement_hold_bound'}
  $exitTicks=$timer.ElapsedTicks;$child.Process.StandardInput.WriteLine('EXIT '+$nonce);$child.Process.StandardInput.Close()
  if(!$child.Process.WaitForExit(10000)){throw 'trial_exit_timeout'}
  $observedExitTicks=$timer.ElapsedTicks
  $after=Get-S20ProcessTimes $child.Handle $true;$jobAfter=Get-S20MeasuredJobSnapshot $job
  $native=Complete-OwnedCapturedProcess $child;$completed=$true
  if($native.native_exit -ne 0 -or !$native.stdout_complete -or !$native.stderr_complete -or $native.output_limit -or $native.capture_fault -or $native.drain_timeout -or $jobAfter.active_processes -ne 0){throw 'trial_native_or_capture_failure'}
 }catch{
  $failureCode=$_.Exception.Message
  if($child -and !$completed){
   try{$job.Stop()}catch{Write-Warning ('trial_job_stop: '+$_.Exception.Message)}
   # An assignment failure leaves this exact owned child outside the nested
   # Job. It still belongs to the outer worker Job; kill only its own handle.
   if(!$child.Process.HasExited){$child.Process.Kill($true)}
   if(!$child.Process.WaitForExit(10000)){throw 'trial_stop_failed'}
   $observedExitTicks=$timer.ElapsedTicks
   $after=Get-S20ProcessTimes $child.Handle $true;$jobAfter=Get-S20MeasuredJobSnapshot $job
   $native=Complete-OwnedCapturedProcess $child;$completed=$true
  }
 }finally{$job.Dispose()}
 $row=@{process_id=$scheduled.process_id;case_id=$scheduled.case_id;regime=$scheduled.regime;status=if($failureCode){'process_failure'}else{'completed'};failure=$failureCode;native_record_path=if($child){Rel ($child.Base+'.process.json')}else{$null};result_directory=Rel $resultDir;live_counters_path=if($live){Rel (Join-Path $trial 'live-counters.json')}else{$null};terminal=$terminal;process_cpu_after_exit=$after;job_after_exit=$jobAfter;stopwatch_frequency=[Diagnostics.Stopwatch]::Frequency;instrumented_process_lifetime_ticks=$observedExitTicks;controller_including_capture_drain_ticks=$timer.ElapsedTicks;boot_ready_ticks=$bootTicks;go_dispatch_ticks=$goTicks;terminal_ready_ticks=$terminalTicks;exit_dispatch_ticks=$exitTicks;argfile_sha256=Get-OwnedHash $argfile;scheduled_calls=$scheduled.iterations;scope='Instrumented wall is pre-spawn to observed native exit, includes both GO/EXIT holds; separate controller duration includes capture draining. Terminal process peaks exclude subsequent teardown. Job interval begins assignment; warm memory covers all five calls, not individual calls.'}
 Write-OwnedJson (Join-Path $trial 'trial.json') $row
 $rows.Add($row)
 Write-OwnedJson (Join-Path $c.output ('checkpoint-'+$scheduled.process_id+'.json')) @{processes=$rows.ToArray();scope='All attempts retained, no acceptance'}
}
[void](Assert-S20MinerEnvironment $c)
Write-OwnedJson (Join-Path $c.output 'index.json') @{schema_version=1;corpus_sha256=Get-OwnedHash $c.corpus;method_sha256=$manifest.method_sha256;build_proof_sha256=Get-OwnedHash $c.build_proof;environment_path='environment.json';environment_sha256=Get-OwnedHash (Join-Path $c.output 'environment.json');processes=$rows.ToArray();benchmark_not_quality_acceptance=$true;native_counter_calibrations=$c.calibrations;hardware_path='hardware.json';hardware_sha256=Get-OwnedHash (Join-Path $c.output 'hardware.json');load_caveat='No other project compiler/evaluator during these serial samples. Unrelated user/OS activity and OS file-cache state are uncontrolled; these tiny synthetic inputs are not production capacity evidence.'}
