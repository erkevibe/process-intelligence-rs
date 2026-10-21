param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output_directory
$expectedTarget=Get-OwnedCanonicalPath (Join-Path $c.workspace '.local/sprint18/root/target')
if($c.target -cne $expectedTarget -or $c.source_commit -cnotmatch '^[0-9a-f]{40}$' -or $c.version -cne '0.7.5'){throw 'release_build_scope'}
Assert-OwnedNoReparse $c.source_directory
Assert-OwnedHash $c.source_archive $c.source_archive_sha
$source=@(Get-ChildItem $c.source_directory -Recurse -File|Sort-Object FullName|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath($c.source_directory,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
$sourceJson=$source|ConvertTo-Json -Depth 5 -Compress
Assert-OwnedHash (Join-Path $c.source_directory 'Cargo.lock') $c.cargo_lock_sha
if((Get-Content (Join-Path $c.source_directory 'Cargo.toml') -Raw) -cnotmatch '(?m)^version = "0\.7\.5"\r?$'){throw 'release_version'}
# A small pinned dispatcher binds the literal Cargo array; no shell-string joining.
$run=Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.dispatch,'-PhaseConfig',$PhaseConfig,'-PhaseConfigSha',$PhaseConfigSha) $c.workspace $c.output_directory 'cargo-release' @{} 1500 16MB
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=@(Get-ChildItem $c.source_directory -Recurse -File|Sort-Object FullName|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath($c.source_directory,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
if(($after|ConvertTo-Json -Depth 5 -Compress) -cne $sourceJson){throw 'frozen_release_source_changed'}
$exe=Join-Path $c.target 'release/process-intelligence-rs.exe'
Assert-OwnedNoReparse $exe
[void](Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('--version','--verbose') $c.workspace $c.output_directory 'cargo-version' @{} 30 1MB)
[void](Invoke-OwnedPhaseCommand $c.rustc $c.rustc_sha @('--version','--verbose') $c.workspace $c.output_directory 'rustc-version' @{} 30 1MB)
$cargoVersion=(Get-Content (Join-Path $c.output_directory 'cargo-version.stdout') -Raw).Trim()
$rustcVersion=(Get-Content (Join-Path $c.output_directory 'rustc-version.stdout') -Raw).Trim()
$buildEnvironment=Get-Content (Join-Path $c.output_directory 'release-cargo-environment.json') -Raw|ConvertFrom-Json
if($buildEnvironment.native_exit -ne 0 -or $buildEnvironment.incremental -cne '0' -or $buildEnvironment.release_debug -cne '0'){throw 'release_dispatch_environment'}
$proof=@{schema_version=1;package_version=$c.version;source_commit=$c.source_commit;source_directory=$c.source_directory;source_archive=$c.source_archive;source_archive_sha256=$c.source_archive_sha;source_files=$after;executable_path=$exe;executable_sha256=Get-OwnedHash $exe;cargo_lock_sha256=$c.cargo_lock_sha;profile='release';build_exit=$run.native_exit;tests_requested=$false;test_exit=$null;build_log=(Join-Path $c.output_directory 'cargo-release.stderr');test_log=$null;cargo_version=$cargoVersion;rustc_version=$rustcVersion;rustup_toolchain=$buildEnvironment.rustup_toolchain;rustflags=$buildEnvironment.rustflags;completed_utc=[DateTime]::UtcNow.ToString('o');scope='Release build of exact Git archive in the single S18 compiler target. Tests have separately named receipts; this proof grants none.'}
Write-OwnedJson (Join-Path $c.output_directory 'build-proof.json') $proof
