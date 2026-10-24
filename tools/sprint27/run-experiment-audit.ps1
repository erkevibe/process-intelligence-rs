param([Parameter(Mandatory)][ValidateSet('inductive','structured')][string]$Kind,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName,[ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$SourceRun='structured01',[ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$ScoreRun='inductive-scores01')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
Import-Module ./tools/sprint21/owned-runtime.psm1 -Global
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$reference=Get-Content .local/sprint19/root/prep01/reference-install-config01.json -Raw|ConvertFrom-Json -AsHashtable
Assert-OwnedHash $reference.python $reference.python_sha
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName)
foreach($name in @('reference','controls','cache','cache/mpl','cache/xdg')){[void](New-OwnedPrivateDirectory (Join-Path $out $name))}
$run=Join-Path $base $SourceRun
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=600;commands=@();pins=@()}
$envs=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1';MPLBACKEND='Agg';MPLCONFIGDIR=(Join-Path $out 'cache/mpl');XDG_CACHE_HOME=(Join-Path $out 'cache/xdg');OMP_NUM_THREADS='1';OPENBLAS_NUM_THREADS='1';MKL_NUM_THREADS='1';NUMEXPR_NUM_THREADS='1';NUMEXPR_MAX_THREADS='1';BLIS_NUM_THREADS='1';VECLIB_MAXIMUM_THREADS='1'}
$sourceDirs=@($run,(Join-Path $base 'inputs01'),(Join-Path $base 'inputs02'),(Join-Path $base 'inputs03'),(Join-Path $base 'sv-original02'))
if($Kind -eq 'structured'){
 $arguments=@('-I','-B','tools/sprint27/audit-structured-comparison.py',$run,$base,(Join-Path $out 'reference'))
 $sourceDirs+=,(Join-Path $base 'inputs03')
 $series=Get-Content (Join-Path $run 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable
 foreach($item in $series.runs){if($item.directory -cnotmatch '^[a-z][a-z0-9-]{0,30}$'){throw 'series_boundary'};$sourceDirs+=,(Join-Path $base $item.directory)}
}else{
 $scores=Join-Path $base $ScoreRun
 $arguments=@('-I','-B','tools/sprint27/audit-inductive-comparison.py',$run,$scores,$base,(Join-Path $out 'reference'))
 $sourceDirs+=,$scores
}
$c.commands+=,@{label='controls';program=$reference.python;sha256=$reference.python_sha;arguments=@('-I','-B','tools/sprint27/auditor-counterfactuals.py',$base,(Join-Path $out 'controls'));directory=$root;environment=$envs;seconds=90;output_limit=1MB;service=$false;process_memory_limit_bytes=512MB}
$c.commands+=,@{label='audit';program=$reference.python;sha256=$reference.python_sha;arguments=$arguments;directory=$root;environment=$envs;seconds=300;output_limit=1MB;service=$false;process_memory_limit_bytes=512MB}
$files=@(Get-ChildItem tools/sprint27 -File)+@(Get-Item tools/oracle/compare-quality-graphs.py,tools/oracle/validate-quality-net-graph.py,tools/sprint19/quality-reference.py,fixtures/sprint26-miner/corpus.json,fixtures/sprint27-miner-validation/corpus.json,fixtures/sprint27-structured/corpus.json)
$files+=@(Get-Item (Join-Path $base 'rust02/observed-r1-linear/result.json'),(Join-Path $base 'rust02/observed-r1-linear/held-out.json'),(Join-Path $base 'audits01/reference/observed-r1-linear-held_out.json'))
foreach($directory in $sourceDirs){$files+=@(Get-ChildItem $directory -Recurse -File|Where-Object {$_.Extension -in @('.json','.bpmn','.stdout','.stderr','.xes','.txt')})}
$c.pins=@($files|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash $_.FullName).Hash}})
$installed=Get-Content .local/sprint19/root/reference-install01/pm4py-original-files.json -Raw|ConvertFrom-Json -AsHashtable
$site=Join-Path $root '.local/sprint19/root/pm4py-env/Lib/site-packages'
foreach($row in $installed.files){$path=[IO.Path]::GetFullPath((Join-Path $site $row.path));if(!$path.StartsWith($site.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'reference_source_boundary'};Assert-OwnedNoReparse $path;Assert-OwnedHash $path $row.sha256;$c.pins+=,@{path=$path;sha256=$row.sha256}}
$before=Assert-S22Capacity $c
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=550;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 3){throw 'audit_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete){throw 'audit_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_COMPLETE_EXPERIMENT_INDEPENDENT_REFERENCE_AUDIT_CLOSED';kind=$Kind;config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;pm4py_source_files_verified=$installed.files.Count;reference_proof_sha256=(Get-FileHash (Join-Path $out 'reference/proof.json')).Hash}
Write-Output 'S27_COMPLETE_EXPERIMENT_AUDIT_CLOSED'
