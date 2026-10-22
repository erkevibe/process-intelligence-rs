param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
Assert-OwnedPrivateDirectory $c.prepared
$files=Get-Content $c.prepared_manifest -Raw|ConvertFrom-Json -AsHashtable
$originalFiles=Get-Content $c.reference_original_files -Raw|ConvertFrom-Json -AsHashtable
if($files.phase -cne 'saved_before_reference_conversion_no_metrics' -or $originalFiles.files.Count -ne 1375){throw 'prepared_or_reference_manifest'}
$checkInputs={
 foreach($row in $files.files){Assert-OwnedHash (Join-Path $c.prepared $row.path) $row.sha256}
 if(@(Get-ChildItem -LiteralPath $c.prepared -Recurse -File -Force).Count -ne $files.files.Count){throw 'prepared_file_set_changed'}
 foreach($row in $originalFiles.files){Assert-OwnedHash (Join-Path $c.reference_site $row.path) $row.sha256}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
}
& $checkInputs
$rust=Invoke-OwnedPhaseCommand $c.observer $c.observer_sha @('score',$c.prepared,(Join-Path $c.output 'rust-metrics.json')) $c.workspace $c.output 'rust-score' @{RAYON_NUM_THREADS='1'} 180 4MB
& $checkInputs
$cache=Join-Path $c.target 'reference-cache'
Assert-OwnedPrivateDirectory $cache
$envs=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1';MPLBACKEND='Agg';MPLCONFIGDIR=(Join-Path $cache 'mpl');XDG_CACHE_HOME=(Join-Path $cache 'xdg');OMP_NUM_THREADS='1';OPENBLAS_NUM_THREADS='1';MKL_NUM_THREADS='1';NUMEXPR_NUM_THREADS='1';NUMEXPR_MAX_THREADS='1';BLIS_NUM_THREADS='1';VECLIB_MAXIMUM_THREADS='1'}
$reference=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B',$c.reference_adapter,'score',$c.prepared,(Join-Path $c.output 'reference-metrics.json')) $c.workspace $c.output 'pm4py-score' $envs 300 8MB
& $checkInputs
Write-OwnedJson (Join-Path $c.output 'score-proof.json') @{status='ACTUAL_SEPARATE_RUST_AND_UNCHANGED_PM4PY_SAME_SAVED_NET_MEASUREMENTS_NOT_ACCEPTANCE';observer_sha256=$c.observer_sha;reference_adapter_sha256=Get-OwnedHash $c.reference_adapter;bundle_sha256=Get-OwnedHash (Join-Path $c.prepared 'bundle.json');rust_native_exit=$rust.native_exit;reference_native_exit=$reference.native_exit;all_prepared_inputs_unchanged=$true;all1375_original_pm4py_files_unchanged=$true;utc=[DateTimeOffset]::UtcNow.ToString('o');not_all_hypotheses_or_R4_acceptance=$true}
