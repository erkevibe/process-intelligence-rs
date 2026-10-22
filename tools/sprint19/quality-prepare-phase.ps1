param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
$proof=Get-Content $c.build_proof -Raw|ConvertFrom-Json -AsHashtable
if($proof.status -cne 'ACTUAL_FROZEN_MANUAL_TESTS_AND_DIAGNOSTIC_BUILD_COMPLETED' -or $proof.observer_sha256 -cne $c.observer_sha){throw 'actual_build_required'}
$originalFiles=Get-Content $c.reference_original_files -Raw|ConvertFrom-Json -AsHashtable
if($originalFiles.status -cne 'ALL_ORIGINAL_WHEEL_MEMBERS_EXCEPT_INSTALLER_REWRITTEN_RECORD_BYTE_IDENTICAL' -or $originalFiles.files.Count -ne 1375){throw 'reference_original_source_manifest'}
foreach($row in $originalFiles.files){Assert-OwnedHash (Join-Path $c.reference_site $row.path) $row.sha256}
$prepared=Join-Path $c.output 'prepared'
$prepare=Invoke-OwnedPhaseCommand $c.observer $c.observer_sha @('prepare',$c.corpus,$prepared) $c.workspace $c.output 'rust-prepare' @{RAYON_NUM_THREADS='1'} 120 4MB
$before=@(Get-ChildItem -LiteralPath $prepared -Recurse -File -Force|Sort-Object FullName|ForEach-Object {@{path=[IO.Path]::GetRelativePath($prepared,$_.FullName);bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
Write-OwnedJson (Join-Path $c.output 'prepared-files-before-reference.json') @{files=$before;phase='saved_before_reference_conversion_no_metrics'}
$cache=Join-Path $c.target 'reference-cache'
Assert-OwnedPrivateDirectory $cache
$envs=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1';MPLBACKEND='Agg';MPLCONFIGDIR=(Join-Path $cache 'mpl');XDG_CACHE_HOME=(Join-Path $cache 'xdg');OMP_NUM_THREADS='1';OPENBLAS_NUM_THREADS='1';MKL_NUM_THREADS='1';NUMEXPR_NUM_THREADS='1';NUMEXPR_MAX_THREADS='1';BLIS_NUM_THREADS='1';VECLIB_MAXIMUM_THREADS='1'}
$reference=Join-Path $c.output 'reference-conversion'
$convert=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B',$c.reference_adapter,'convert',$prepared,$reference) $c.workspace $c.output 'pm4py-convert' $envs 180 4MB
foreach($row in $before){Assert-OwnedHash (Join-Path $prepared $row.path) $row.sha256}
if(@(Get-ChildItem -LiteralPath $prepared -Recurse -File -Force).Count -ne $before.Count){throw 'prepared_file_set_changed'}
foreach($row in $originalFiles.files){Assert-OwnedHash (Join-Path $c.reference_site $row.path) $row.sha256}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'prepare-proof.json') @{status='ACTUAL_RUST_SAVED_NETS_AND_UNCHANGED_PM4PY_ORIGINAL_BPMN_CONVERSION_NOT_METRICS_OR_ACCEPTANCE';observer_sha256=$c.observer_sha;reference_adapter_sha256=Get-OwnedHash $c.reference_adapter;prepared=$prepared;reference_conversion=$reference;rust_native_exit=$prepare.native_exit;reference_native_exit=$convert.native_exit;prepared_files_unchanged=$true;no_scoring=$true;utc=[DateTimeOffset]::UtcNow.ToString('o')}
