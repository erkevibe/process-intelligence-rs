param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.source_directory
Assert-OwnedPrivateDirectory $c.output
Assert-OwnedHash $c.source_archive $c.source_archive_sha
$inventory=Get-Content -LiteralPath $c.source_inventory -Raw|ConvertFrom-Json -AsHashtable
function Assert-FrozenSource {
 $files=@(Get-ChildItem -LiteralPath $c.source_directory -File -Recurse -Force)
 if($files.Count -ne $inventory.files.Count){throw 'source_file_set'}
 foreach($row in $inventory.files){
  $path=Join-Path $c.source_directory $row.path
  Assert-OwnedNoReparse $path;Assert-OwnedHash $path $row.sha256
  if((Get-Item -LiteralPath $path).Length -ne $row.bytes){throw 'source_length'}
 }
}
Assert-FrozenSource
$manifest=Join-Path $c.source_directory 'Cargo.toml'
$fmt=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('fmt','--all','--manifest-path',$manifest,'--','--check') $c.source_directory $c.output 'fmt' @{} 60 2MB
$tests=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('test','--offline','--locked','--test','sprint20_conversion','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2') $c.source_directory $c.output 'conversion-tests' @{RAYON_NUM_THREADS='1'} 600 8MB
$build=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('build','--offline','--locked','--example','pi_convert','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2') $c.source_directory $c.output 'conversion-build' @{RAYON_NUM_THREADS='1'} 600 8MB
$clippy=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('clippy','--offline','--locked','--example','pi_convert','--test','sprint20_conversion','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2','--','-D','warnings') $c.source_directory $c.output 'conversion-clippy' @{RAYON_NUM_THREADS='1'} 600 8MB
Assert-FrozenSource
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$exe=Join-Path $c.target 'debug/examples/pi_convert.exe'
Write-OwnedJson (Join-Path $c.output 'build-proof.json') @{status='ACTUAL_FROZEN_CONVERTER_BUILD_AND_INTEGRATION_TESTS';source_archive_sha256=$c.source_archive_sha;source_inventory_sha256=Get-OwnedHash $c.source_inventory;executable=$exe;executable_sha256=Get-OwnedHash $exe;fmt_native_exit=$fmt.native_exit;test_native_exit=$tests.native_exit;build_native_exit=$build.native_exit;clippy_native_exit=$clippy.native_exit;frozen_source_unchanged=$true;fixture_acceptance_not_claimed=$true;product075_untouched=$true}
