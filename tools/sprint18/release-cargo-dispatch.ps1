param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'release_config_sha'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256.ToUpperInvariant()){throw 'release_input_pin'}}
$env:CARGO_PROFILE_RELEASE_DEBUG='0';$env:CARGO_INCREMENTAL='0'
& $c.cargo @('build','--offline','--locked','--release','--manifest-path',(Join-Path $c.source_directory 'Cargo.toml'),'--target-dir',$c.target,'--jobs','2')
$nativeExit=$LASTEXITCODE
[IO.File]::WriteAllText((Join-Path $c.output_directory 'release-cargo-environment.json'),(@{native_exit=$nativeExit;rustup_toolchain=$env:RUSTUP_TOOLCHAIN;rustflags=$env:CARGO_ENCODED_RUSTFLAGS;incremental=$env:CARGO_INCREMENTAL;release_debug=$env:CARGO_PROFILE_RELEASE_DEBUG}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
exit $nativeExit
