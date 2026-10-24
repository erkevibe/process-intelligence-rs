param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-measured-broker.ps1
Import-Module ./tools/sprint21/owned-runtime.psm1 -Global
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$tools=Get-Content .local/sprint21/root/sprint25/pg-recovery-config04.json -Raw|ConvertFrom-Json -AsHashtable
$reference=Get-Content .local/sprint19/root/prep01/reference-install-config01.json -Raw|ConvertFrom-Json -AsHashtable
Assert-OwnedHash $reference.python $reference.python_sha
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName)
foreach($name in @('graphs','reference','cache','cache/mpl','cache/xdg')){[void](New-OwnedPrivateDirectory (Join-Path $out $name))}
$run=Join-Path $base 'rust02';$inputs=Join-Path $base 'inputs01'
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=600;commands=@();pins=@()}
$normal=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'}
$refenv=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1';MPLBACKEND='Agg';MPLCONFIGDIR=(Join-Path $out 'cache/mpl');XDG_CACHE_HOME=(Join-Path $out 'cache/xdg');OMP_NUM_THREADS='1';OPENBLAS_NUM_THREADS='1';MKL_NUM_THREADS='1';NUMEXPR_NUM_THREADS='1';NUMEXPR_MAX_THREADS='1';BLIS_NUM_THREADS='1';VECLIB_MAXIMUM_THREADS='1'}
$c.commands+=,@{label='graph-audit';program=$tools.python;sha256=(Get-FileHash $tools.python).Hash;arguments=@('-I','-B','tools/sprint27/audit-rust-comparison.py',$run,$inputs,(Join-Path $out 'graphs'));directory=$root;environment=$normal;seconds=90;output_limit=1MB;service=$false}
$c.commands+=,@{label='metric-reference';program=$reference.python;sha256=$reference.python_sha;arguments=@('-I','-B','tools/sprint27/reference-rust-comparison.py',$run,(Join-Path $out 'graphs'),(Join-Path $out 'reference'));directory=$root;environment=$refenv;seconds=180;output_limit=1MB;service=$false}
$files=@(Get-Item tools/sprint27/audit-rust-comparison.py,tools/sprint27/reference-rust-comparison.py,tools/sprint27/run-rust-audits.ps1,tools/sprint27/load-measured-broker.ps1,tools/sprint27/comparison-worker.ps1,tools/oracle/compare-quality-graphs.py,tools/oracle/validate-quality-net-graph.py,tools/sprint19/quality-reference.py)
$files+=@(Get-ChildItem $run -Recurse -File|Where-Object {$_.Extension -in @('.json','.bpmn','.stdout','.stderr')})
$files+=@(Get-ChildItem $inputs -File)
$c.pins=@($files|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash $_.FullName).Hash}})
$installed=Get-Content .local/sprint19/root/reference-install01/pm4py-original-files.json -Raw|ConvertFrom-Json -AsHashtable
$site=Join-Path $root '.local/sprint19/root/pm4py-env/Lib/site-packages'
foreach($row in $installed.files){$path=[IO.Path]::GetFullPath((Join-Path $site $row.path));if(!$path.StartsWith($site.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'reference_source_boundary'};Assert-OwnedNoReparse $path;Assert-OwnedHash $path $row.sha256;$c.pins+=,@{path=$path;sha256=$row.sha256}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$before=Assert-S22Capacity $c
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=550;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 3){throw 'reference_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete){throw 'reference_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_RUST_GRAPH_AND_UNCHANGED_PM4PY_REFERENCE_AUDITS_CLOSED';config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;reference_source_files_verified=$installed.files.Count}
Write-Output 'S27_RUST_REFERENCE_AUDITS_CLOSED'
