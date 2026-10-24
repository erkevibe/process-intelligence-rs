param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName,[ValidateSet('original','validation')][string]$InputSet='original')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
$taskRoot=[string]$PWD;$taskBase=Join-Path $taskRoot '.local/sprint21/root/sprint27'
$taskBuildConfig=Get-Content (Join-Path $taskBase 'compile02-config.json') -Raw|ConvertFrom-Json -AsHashtable
$taskBuild=Get-Content (Join-Path $taskBase 'compile02/proof.json') -Raw|ConvertFrom-Json -AsHashtable
if($taskBuild.status -cne 'DIRECT_OWNED_CARGO_COMMANDS_CLOSED' -or @($taskBuild.records|Where-Object {$_.native_exit -ne 0 -or !$_.stdout_complete -or !$_.stderr_complete}).Count){throw 'release_build_required'}
foreach($pin in $taskBuildConfig.pins){Assert-OwnedHash $pin.path $pin.sha256}
$taskOld=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$taskCalibration=Get-Content (Join-Path $taskBase 'counter-calibration02/proof.json') -Raw|ConvertFrom-Json -AsHashtable
if($taskCalibration.status -cne 'S27_LIFETIME_PEAK_COUNTER_CALIBRATION_PASS'){throw 'calibrated_native_counters_required'}
$taskLimit=Get-Content (Join-Path $taskBase 'limit-calibration01/proof.json') -Raw|ConvertFrom-Json -AsHashtable
if($taskLimit.status -cne 'S27_OS_PROCESS_COMMIT_LIMIT_POSITIVE_AND_NEGATIVE_CONTROLS_PASS'){throw 'os_memory_limit_calibration_required'}
$taskInputs=Join-Path $taskBase $(if($InputSet -eq 'original'){'inputs01'}else{'inputs02'});Assert-OwnedPrivateDirectory $taskInputs
$taskManifest=Get-Content (Join-Path $taskInputs 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable
$taskCorpus=if($InputSet -eq 'original'){'a00e03010eb1d8f5f8f11e9533abdcf72507c86300ad54e1ac251f74ad7aa68c'}else{'891b1f4306850ac0abd02a2afaeafa61a892847fbf2e73a44b02bdc06bbafa17'};if($taskManifest.corpus_sha256 -cne $taskCorpus -or $taskManifest.cases.Count -ne 7){throw 'prospective_corpus_required'}
$taskOut=New-OwnedPrivateDirectory (Join-Path $taskBase $RunName)
$taskProgram=Join-Path $taskRoot '.local/sprint21/root/target/release/examples/miner_alpha_profiles.exe'
# The broker checks program and parent reparse boundaries before every admission.
$taskSha=(Get-FileHash $taskProgram).Hash
$c=@{workspace=$taskRoot;output=$taskOut;deadline_utc='2026-10-24T17:14:49Z';session_seconds=900;commands=@();pins=$taskBuildConfig.pins}
foreach($repetition in 1..2){foreach($algorithm in @('alpha-default','alpha-repair')){foreach($case in $taskManifest.cases){
 if($case.id -cnotmatch '^[a-z][a-z0-9_]{0,63}$' -or $case.input_file -cne ($case.id+'.json')){throw 'case_identity'}
 $input=Join-Path $taskInputs $case.input_file;Assert-OwnedHash $input $case.input_sha256.ToUpperInvariant()
 $c.pins+=,@{path=$input;sha256=$case.input_sha256.ToUpperInvariant()}
 $label=($algorithm+'-r'+$repetition+'-'+$case.id.Replace('_','-'))
 $output=New-OwnedPrivateDirectory (Join-Path $taskOut $label)
 $environment=@{RAYON_NUM_THREADS='1';TEMP=$taskBuildConfig.environment.TEMP;TMP=$taskBuildConfig.environment.TMP}
 $c.commands+=,@{label=$label;program=$taskProgram;sha256=$taskSha;arguments=@($algorithm,$input,$output);directory=$taskRoot;environment=$environment;seconds=60;output_limit=1MB;service=$false;process_memory_limit_bytes=512MB}
}}}
$worker=Join-Path $taskRoot 'tools/sprint27/comparison-worker.ps1'
foreach($path in @($worker,(Join-Path $taskRoot 'tools/sprint27/load-limited-broker.ps1'),(Join-Path $taskRoot 'tools/sprint27/run-alpha-profiles.ps1'))){$c.pins+=,@{path=$path;sha256=(Get-FileHash $path).Hash}}
$before=Assert-S22Capacity $c
if($before.root_logical_bytes+512MB -gt (10GB-512MB) -or $before.root_allocation_bytes+512MB -gt (10GB-512MB) -or $before.logical_bytes+512MB -gt (14GB-512MB) -or $before.allocation_bytes+512MB -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+512MB)){throw 'bounded_comparison_reserve'}
$config=Join-Path $taskOut 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $taskOut 'session')
$command=@{label='worker';program=$taskOld.pwsh;sha256=$taskOld.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$taskRoot;environment=@{};seconds=850;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 29){throw 'comparison_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or !$record.lifetime_memory_after_exit -or !$record.lifetime_times_after_exit){throw 'comparison_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $taskOut 'proof.json') @{status='S27_ALPHA_DEFAULT_AND_REPAIR_CAPTURED_PENDING_GRAPH_AUDIT';config_sha256=(Get-FileHash $config).Hash;program_sha256=$taskSha;calibration_sha256=(Get-FileHash (Join-Path $taskBase 'counter-calibration02/proof.json')).Hash;records=$r.records;before=$before;after=$after;repetitions=2;algorithms=@('alpha-default','alpha-repair');not_statistical_benchmark=$true}
Write-Output 'S27_RUST_COMPARISON_NATIVE_CLOSED'
