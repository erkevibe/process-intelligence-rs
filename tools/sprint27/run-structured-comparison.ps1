param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName,[Parameter(Mandatory)][ValidateSet('original','validation','structured')][string]$InputSet,[ValidatePattern('^compile[0-9]{2}$')][string]$BuildRun='compile04')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$buildConfig=Get-Content (Join-Path $base ($BuildRun+'-config.json')) -Raw|ConvertFrom-Json -AsHashtable
$build=Get-Content (Join-Path $base ($BuildRun+'/proof.json')) -Raw|ConvertFrom-Json -AsHashtable
if($build.status -cne 'DIRECT_OWNED_CARGO_COMMANDS_CLOSED' -or @($build.records|Where-Object {$_.native_exit -ne 0 -or !$_.stdout_complete -or !$_.stderr_complete}).Count){throw 'release_build_required'}
foreach($pin in $buildConfig.pins){Assert-OwnedHash $pin.path $pin.sha256}
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$limit=Get-Content (Join-Path $base 'limit-calibration01/proof.json') -Raw|ConvertFrom-Json -AsHashtable
if($limit.status -cne 'S27_OS_PROCESS_COMMIT_LIMIT_POSITIVE_AND_NEGATIVE_CONTROLS_PASS'){throw 'os_memory_limit_required'}
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName)
$program=Join-Path $root '.local/sprint21/root/target/release/examples/miner_structured.exe';$sha=(Get-FileHash $program).Hash
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=600;commands=@();pins=$buildConfig.pins}
$sets=@(@{name='original';directory='inputs01';sha='a00e03010eb1d8f5f8f11e9533abdcf72507c86300ad54e1ac251f74ad7aa68c'},@{name='validation';directory='inputs02';sha='891b1f4306850ac0abd02a2afaeafa61a892847fbf2e73a44b02bdc06bbafa17'},@{name='structured';directory='inputs03';sha='a6db9120518d4adfdfcb2648c6bba08efbd2757b4a36be50aafb50db795018e6'})
foreach($repetition in 1..2){foreach($set in @($sets|Where-Object name -CEQ $InputSet)){
 $inputs=Join-Path $base $set.directory;$manifestPath=Join-Path $inputs 'manifest.json';$manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json -AsHashtable
 if($manifest.corpus_sha256 -cne $set.sha -or $manifest.cases.Count -ne 7){throw 'prospective_corpus'}
 $c.pins+=,@{path=$manifestPath;sha256=(Get-FileHash $manifestPath).Hash}
 foreach($case in $manifest.cases){
  if($case.id -cnotmatch '^[a-z][a-z_]{0,63}$' -or $case.input_file -cne ($case.id+'.json')){throw 'case_identity'}
  $input=Join-Path $inputs $case.input_file;Assert-OwnedHash $input $case.input_sha256.ToUpperInvariant();$c.pins+=,@{path=$input;sha256=$case.input_sha256.ToUpperInvariant()}
  $label='sv-'+$set.name+'-r'+$repetition+'-'+$case.id.Replace('_','-');if($label.Length -gt 48){throw 'native_label_bound'};$directory=New-OwnedPrivateDirectory (Join-Path $out $label)
  $c.commands+=,@{label=$label;program=$program;sha256=$sha;arguments=@($input,$directory);directory=$root;environment=@{RAYON_NUM_THREADS='1';TEMP=$buildConfig.environment.TEMP;TMP=$buildConfig.environment.TMP};seconds=60;output_limit=1MB;service=$false;process_memory_limit_bytes=512MB}
 }
}}
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
foreach($path in @($worker,(Join-Path $root 'tools/sprint27/load-limited-broker.ps1'),(Join-Path $root 'tools/sprint27/run-structured-comparison.ps1'),(Join-Path $base 'limit-calibration01/proof.json'),(Join-Path $base 'counter-calibration02/proof.json'))){$c.pins+=,@{path=$path;sha256=(Get-FileHash $path).Hash}}
$before=Assert-S22Capacity $c
if($before.root_logical_bytes+512MB -gt (10GB-512MB) -or $before.root_allocation_bytes+512MB -gt (10GB-512MB) -or $before.logical_bytes+512MB -gt (14GB-512MB) -or $before.allocation_bytes+512MB -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+512MB)){throw 'bounded_comparison_reserve'}
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=550;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 15){throw 'structured_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or !$record.lifetime_memory_after_exit){throw 'structured_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_ACTUAL_STRUCTURED_VARIANTS_CAPTURED_PENDING_INDEPENDENT_AUDIT';config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;algorithm='structured_variants_v1';repetitions=2;corpus=$InputSet;not_statistical_benchmark=$true}
Write-Output 'S27_STRUCTURED_NATIVE_CLOSED'
