param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.source_directory
Assert-OwnedPrivateDirectory $c.output
Assert-OwnedHash $c.source_archive $c.source_archive_sha
$snapshot={@(Get-ChildItem $c.source_directory -File -Recurse -Force|Sort-Object FullName|ForEach-Object {@{path=[IO.Path]::GetRelativePath($c.source_directory,$_.FullName);bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})|ConvertTo-Json -Compress -Depth 4}
$before=& $snapshot
$manifest=Join-Path $c.source_directory 'Cargo.toml'
$fmt=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('fmt','--all','--manifest-path',$manifest,'--','--check') $c.source_directory $c.output 'fmt' @{} 60 1MB
$test=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('test','--offline','--locked','--test','sprint19_quality','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2') $c.source_directory $c.output 'quality-tests' @{RAYON_NUM_THREADS='1'} 600 8MB
$build=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('build','--offline','--locked','--example','bpmn_quality','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2') $c.source_directory $c.output 'quality-build' @{RAYON_NUM_THREADS='1'} 600 8MB
$clippy=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('clippy','--offline','--locked','--example','bpmn_quality','--test','sprint19_quality','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2','--','-D','warnings') $c.source_directory $c.output 'quality-clippy' @{RAYON_NUM_THREADS='1'} 600 8MB
if((& $snapshot) -cne $before){throw 'frozen_source_changed'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$exe=Join-Path $c.target 'debug/examples/bpmn_quality.exe'
Write-OwnedJson (Join-Path $c.output 'build-proof.json') @{status='ACTUAL_FROZEN_MANUAL_TESTS_AND_DIAGNOSTIC_BUILD_COMPLETED';source_commit=$c.source_commit;source_archive_sha256=$c.source_archive_sha;observer_executable=$exe;observer_sha256=Get-OwnedHash $exe;fmt_native_exit=$fmt.native_exit;test_native_exit=$test.native_exit;build_native_exit=$build.native_exit;clippy_native_exit=$clippy.native_exit;full_source_unchanged=$true;no_saved_bpmn_preparation_or_final_measurement=$true;product075_untouched=$true}
