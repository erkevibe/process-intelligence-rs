param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
Import-Module ./tools/sprint21/owned-runtime.psm1 -Global
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$reference=Get-Content .local/sprint19/root/prep01/reference-install-config01.json -Raw|ConvertFrom-Json -AsHashtable
Assert-OwnedHash $reference.python $reference.python_sha
$limit=Get-Content (Join-Path $base 'limit-calibration01/proof.json') -Raw|ConvertFrom-Json -AsHashtable
if($limit.status -cne 'S27_OS_PROCESS_COMMIT_LIMIT_POSITIVE_AND_NEGATIVE_CONTROLS_PASS'){throw 'os_memory_limit_calibration_required'}
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName)
foreach($name in @('cache','cache/mpl','cache/xdg','cache/tmp')){[void](New-OwnedPrivateDirectory (Join-Path $out $name))}
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=1200;commands=@();pins=@()}
$envs=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1';MPLBACKEND='Agg';MPLCONFIGDIR=(Join-Path $out 'cache/mpl');XDG_CACHE_HOME=(Join-Path $out 'cache/xdg');TEMP=(Join-Path $out 'cache/tmp');TMP=(Join-Path $out 'cache/tmp');OMP_NUM_THREADS='1';OPENBLAS_NUM_THREADS='1';MKL_NUM_THREADS='1';NUMEXPR_NUM_THREADS='1';NUMEXPR_MAX_THREADS='1';BLIS_NUM_THREADS='1';VECLIB_MAXIMUM_THREADS='1';PYTHONHASHSEED='0'}
foreach($repetition in 1..2){foreach($set in @('original','validation')){
 $inputs=Join-Path $base $(if($set -eq 'original'){'inputs01'}else{'inputs02'})
 $manifest=Get-Content (Join-Path $inputs 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable
 $expected=if($set -eq 'original'){'a00e03010eb1d8f5f8f11e9533abdcf72507c86300ad54e1ac251f74ad7aa68c'}else{'891b1f4306850ac0abd02a2afaeafa61a892847fbf2e73a44b02bdc06bbafa17'}
 if($manifest.corpus_sha256 -cne $expected -or $manifest.cases.Count -ne 7){throw 'prospective_corpus'}
 foreach($case in $manifest.cases){
  if($case.id -cnotmatch '^[a-z][a-z_]{0,63}$' -or $case.xes_file -cne ($case.id+'.xes')){throw 'input_identity'}
  $input=Join-Path $inputs $case.xes_file;Assert-OwnedHash $input $case.xes_sha256.ToUpperInvariant();$c.pins+=,@{path=$input;sha256=$case.xes_sha256.ToUpperInvariant()}
  $label='im-'+$set+'-r'+$repetition+'-'+$case.id.Replace('_','-');$directory=New-OwnedPrivateDirectory (Join-Path $out $label)
  $c.commands+=,@{label=$label;program=$reference.python;sha256=$reference.python_sha;arguments=@('-I','-B','tools/sprint27/inductive-miner.py',$input,$directory);directory=$root;environment=$envs;seconds=60;output_limit=1MB;service=$false;process_memory_limit_bytes=512MB}
 }
}}
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
$files=@(Get-Item tools/sprint27/inductive-miner.py,tools/sprint27/audit-rust-comparison.py,tools/sprint27/load-limited-broker.ps1,tools/sprint27/run-inductive-comparison.ps1,tools/sprint27/comparison-worker.ps1,tools/oracle/compare-quality-graphs.py,tools/oracle/validate-quality-net-graph.py,tools/sprint19/quality-reference.py,docs/MINER_INDUCTIVE_PHASE.md,fixtures/sprint26-miner/corpus.json,fixtures/sprint27-miner-validation/corpus.json)
$c.pins+=@($files|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash $_.FullName).Hash}})
$installed=Get-Content .local/sprint19/root/reference-install01/pm4py-original-files.json -Raw|ConvertFrom-Json -AsHashtable
$site=Join-Path $root '.local/sprint19/root/pm4py-env/Lib/site-packages'
foreach($row in $installed.files){$path=[IO.Path]::GetFullPath((Join-Path $site $row.path));if(!$path.StartsWith($site.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'source_boundary'};Assert-OwnedNoReparse $path;Assert-OwnedHash $path $row.sha256;$c.pins+=,@{path=$path;sha256=$row.sha256}}
$before=Assert-S22Capacity $c
if($before.root_logical_bytes+512MB -gt (10GB-512MB) -or $before.root_allocation_bytes+512MB -gt (10GB-512MB) -or $before.logical_bytes+512MB -gt (14GB-512MB) -or $before.allocation_bytes+512MB -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+512MB)){throw 'bounded_comparison_reserve'}
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=1150;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 29){throw 'inductive_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or !$record.lifetime_memory_after_exit){throw 'inductive_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_ACTUAL_PM4PY_IM_CAPTURED_PENDING_INDEPENDENT_AUDIT';config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;source_files_verified=$installed.files.Count;algorithm='pm4py-inductive-im';repetitions=2;corpora=2;not_statistical_benchmark=$true}
Write-Output 'S27_PM4PY_IM_NATIVE_CLOSED'
