param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output_directory
foreach($mode in @('fmt','clippy','test','model')){
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.dispatch,'-Mode',$mode) $c.workspace $c.output_directory ('cargo-'+$mode) @{} 600 16MB)
}
$model=Get-Content (Join-Path $c.output_directory 'cargo-model.stdout') -Raw|ConvertFrom-Json -DateKind String
if($model.status -cne 'PUBLIC_FIXTURE_TYPED_SERIALIZATION_CALIBRATION' -or $model.typed_model_sha256 -cne '28a17356478c1a52a609f6f3bf59e01907671c4c4fcfb9211d2cb7f1a3a7f28c'){throw 'fixed_model_serialization_changed'}
foreach($script in @('sql5-cycle-regression.cjs','cleanup-boundary-regression.cjs','stock-state-compare-regression.cjs','auth-delta-regression.cjs','audit-retention-regression.cjs','sprint12-project-selector.cjs')){
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @((Join-Path $c.workspace ('tests/'+$script))) $c.workspace $c.output_directory ('node-'+$script.Replace('.cjs','')) @{} 120 4MB)
}
foreach($kind in @('folder','project','resource')){
 $fixture=Join-Path $c.output_directory ('node-'+$kind+'-fixture');[void](New-OwnedPrivateDirectory $fixture)
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @((Join-Path $c.workspace ('tests/sprint12-'+$kind+'-oracle.cjs')),$fixture) $c.workspace $c.output_directory ('node-'+$kind+'-oracle') @{} 120 4MB)
}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output_directory 'checks-result.json') @{status='LOCAL_FORMAT_CLIPPY_TESTS_MODEL_AND_NODE_CHECKS_PASSED';cargo_modes=@('fmt','clippy','test','model');node_scripts=9;limits=@('Ignored PostgreSQL tests are separately accepted only by actual native fixture receipts','No GitHub CI or release delivery inferred from local checks')}
