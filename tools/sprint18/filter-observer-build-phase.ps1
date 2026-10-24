param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.source_directory
Assert-OwnedPrivateDirectory $c.output_directory
if($c.target -cne (Join-Path $c.workspace '.local/sprint18/root/target')){throw 'observer_target_scope'}
Assert-OwnedHash $c.source_archive $c.source_archive_sha
$snapshot={@(Get-ChildItem $c.source_directory -File -Recurse -Force|Sort-Object FullName|ForEach-Object {@{path=[IO.Path]::GetRelativePath($c.source_directory,$_.FullName);bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})|ConvertTo-Json -Compress -Depth 4}
$before=& $snapshot
$args=@('build','--offline','--locked','--example','core_filter_observer','--manifest-path',(Join-Path $c.source_directory 'Cargo.toml'),'--target-dir',$c.target,'--jobs','2')
$native=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha $args $c.source_directory $c.output_directory 'observer-build' @{} 600 8MB
if((& $snapshot) -cne $before){throw 'frozen_observer_source_changed'}
$exe=Join-Path $c.target 'debug/examples/core_filter_observer.exe'
Assert-OwnedNoReparse $exe
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output_directory 'observer-build-proof.json') @{status='BUILT_NOT_EXECUTED';source_commit=$c.source_commit;source_archive_sha256=$c.source_archive_sha;executable_path=$exe;executable_sha256=Get-OwnedHash $exe;native_exit=$native.native_exit;full_source_unchanged=$true;scope='Diagnostic calls unchanged production filter; no product executable or case-execution credit'}
