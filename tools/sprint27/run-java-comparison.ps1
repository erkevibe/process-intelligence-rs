param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-measured-broker.ps1
Import-Module ./tools/sprint21/owned-runtime.psm1 -Global
Import-Module ./tools/sprint20/miner-support.psm1 -Force
Import-Module ./tools/sprint20/miner-environment.psm1 -Force
$taskRoot=[string]$PWD;$taskBase=Join-Path $taskRoot '.local/sprint21/root/sprint27'
$taskCanonical=Get-Content .local/sprint20/root/unprojected-public-copy01/provenance/configs/miner-benchmark-config01.json -Raw|ConvertFrom-Json -AsHashtable
$taskCanonical.phase_deadline_utc='2026-10-24T17:14:49Z'
$taskClasspath=Assert-S20MinerEnvironment $taskCanonical
$taskOld=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$taskCalibration=Get-Content (Join-Path $taskBase 'counter-calibration02/proof.json') -Raw|ConvertFrom-Json -AsHashtable
if($taskCalibration.status -cne 'S27_LIFETIME_PEAK_COUNTER_CALIBRATION_PASS'){throw 'calibrated_native_counters_required'}
$taskHarness=Join-Path $taskRoot '.local/sprint16/service/miner-observer01/classes'
$taskHarnessFile=Join-Path $taskHarness 'FullMinerHarness.class'
Assert-OwnedHash $taskHarnessFile '14F897B806880E041643E98F5D554BD9DB07572A8D12090B798D76C1BBC833CE'
Assert-OwnedHash (Join-Path $taskRoot 'tools/oracle/full-miner-harness.java') '0F0321853E35966D996101B1038058FC39E304DD33621366A55A13358DAB902C'
$taskCompile=Get-Content .local/sprint16/service/miner-observer01/compile/child.process.json -Raw|ConvertFrom-Json -AsHashtable
if($taskCompile.native_exit -ne 0 -or !$taskCompile.stdout_complete -or !$taskCompile.stderr_complete){throw 'existing_harness_build_not_complete'}
$taskClasspath=$taskHarness+';'+$taskClasspath
$taskIdentity=& (Get-Module miner-environment) {param([string]$Classpath) Get-S20ClassResource $Classpath 'org.apromore.splitminer.SplitMiner'} $taskClasspath
if($taskIdentity.sha256 -cne 'e8535a6b65b7e758a49e757d635e8797071b8e860bc8d1c6859e592eb1ee21ad'){throw 'actual_miner_identity'}
$taskInputs=Join-Path $taskBase 'inputs01';Assert-OwnedPrivateDirectory $taskInputs
$taskManifest=Get-Content (Join-Path $taskInputs 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable
if($taskManifest.corpus_sha256 -cne 'a00e03010eb1d8f5f8f11e9533abdcf72507c86300ad54e1ac251f74ad7aa68c' -or $taskManifest.cases.Count -ne 7){throw 'prospective_corpus_required'}
$taskOut=New-OwnedPrivateDirectory (Join-Path $taskBase $RunName)
$c=@{workspace=$taskRoot;output=$taskOut;deadline_utc='2026-10-24T17:14:49Z';session_seconds=900;commands=@();pins=$taskCanonical.pins}
$c.pins+=,@{path=$taskHarnessFile;sha256=(Get-FileHash $taskHarnessFile).Hash}
foreach($repetition in 1..2){foreach($case in $taskManifest.cases){
 if($case.id -cnotmatch '^[a-z][a-z0-9_]{0,63}$' -or $case.xes_file -cne ($case.id+'.xes')){throw 'case_identity'}
 $input=Join-Path $taskInputs $case.xes_file;Assert-OwnedHash $input $case.xes_sha256.ToUpperInvariant();$c.pins+=,@{path=$input;sha256=$case.xes_sha256.ToUpperInvariant()}
 $label=('split-r'+$repetition+'-'+$case.id.Replace('_','-'))
 $output=New-OwnedPrivateDirectory (Join-Path $taskOut $label)
 $jvm=New-OwnedPrivateDirectory (Join-Path $output 'jvm');$environment=New-S20JavaEnvironment $jvm
 $arguments=@(Get-S20JvmArgs $jvm|ForEach-Object {([string]$_).Replace('-XX:ActiveProcessorCount=2','-XX:ActiveProcessorCount=1')})+@('-classpath',$taskClasspath,'FullMinerHarness',$input,(Join-Path $output 'result.json'),(Join-Path $output 'model.bpmn'))
 $argfile=Join-Path $output 'java.args';Write-S20JavaArgs $argfile $arguments
 $c.pins+=,@{path=$argfile;sha256=(Get-FileHash $argfile).Hash}
 $c.commands+=,@{label=$label;program=$taskCanonical.java;sha256=$taskCanonical.java_sha;arguments=@('@'+$argfile);directory=(Join-Path $jvm 'cwd');environment=$environment;seconds=60;output_limit=1MB;service=$false}
}}
$worker=Join-Path $taskRoot 'tools/sprint27/comparison-worker.ps1'
foreach($path in @($worker,(Join-Path $taskRoot 'tools/sprint27/load-measured-broker.ps1'),(Join-Path $taskRoot 'tools/sprint27/run-java-comparison.ps1'))){$c.pins+=,@{path=$path;sha256=(Get-FileHash $path).Hash}}
$before=Assert-S22Capacity $c
if($before.root_logical_bytes+512MB -gt (10GB-512MB) -or $before.root_allocation_bytes+512MB -gt (10GB-512MB) -or $before.logical_bytes+512MB -gt (14GB-512MB) -or $before.allocation_bytes+512MB -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+512MB)){throw 'bounded_comparison_reserve'}
$config=Join-Path $taskOut 'config.json';Write-OwnedJson $config $c
Write-OwnedJson (Join-Path $taskOut 'engine-identity.json') @{status='UNCHANGED_CANONICAL_SPLITMINER_AND_EXISTING_HARNESS';miner=$taskIdentity;harness_sha256=(Get-FileHash $taskHarnessFile).Hash;harness_source_sha256=(Get-FileHash tools/oracle/full-miner-harness.java).Hash;canonical_classpath_sha256=$taskCanonical.classpath_sha;jvm_heap_mib=512;jvm_active_processor_count=1;input_is_training_only=$true}
$session=New-OwnedPrivateDirectory (Join-Path $taskOut 'session')
$command=@{label='worker';program=$taskOld.pwsh;sha256=$taskOld.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$taskRoot;environment=@{};seconds=850;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 15){throw 'comparison_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or !$record.lifetime_memory_after_exit -or !$record.lifetime_times_after_exit){throw 'comparison_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
[void](Assert-S20MinerEnvironment $taskCanonical)
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $taskOut 'proof.json') @{status='S27_ACTUAL_SPLITMINER_COMPARISON_CAPTURED_PENDING_SEMANTIC_AUDIT';config_sha256=(Get-FileHash $config).Hash;engine_identity_sha256=(Get-FileHash (Join-Path $taskOut 'engine-identity.json')).Hash;calibration_sha256=(Get-FileHash (Join-Path $taskBase 'counter-calibration02/proof.json')).Hash;records=$r.records;before=$before;after=$after;repetitions=2;not_statistical_benchmark=$true;canonical_runtime_unchanged_before_after=$true}
Write-Output 'S27_JAVA_COMPARISON_NATIVE_CLOSED'
