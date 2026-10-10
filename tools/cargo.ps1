param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CargoArgs)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskLocalCargo=Join-Path $taskRoot '.local\cargo\bin\cargo.exe'
if(Test-Path -LiteralPath $taskLocalCargo){
    $env:CARGO_HOME=Join-Path $taskRoot '.local\cargo'
    $env:RUSTUP_HOME=Join-Path $taskRoot '.local\rustup'
    $taskPinned=Join-Path $env:RUSTUP_HOME 'toolchains\1.99.0-x86_64-pc-windows-gnu'
    $taskChannel=if(Test-Path -LiteralPath $taskPinned){'1.99.0-x86_64-pc-windows-gnu'}else{'stable-x86_64-pc-windows-gnu'}
    $env:RUSTUP_TOOLCHAIN=$taskChannel
    $taskToolchainBin=Join-Path $env:RUSTUP_HOME "toolchains\$taskChannel\lib\rustlib\x86_64-pc-windows-gnu\bin"
    $taskSelfContained=Join-Path $taskToolchainBin 'self-contained'
    $env:PATH="$taskSelfContained;$taskToolchainBin;$(Split-Path -Parent $taskLocalCargo);$env:PATH"
    $taskDlltool=Join-Path $taskRoot '.local\bin\llvm-dlltool.exe'
    if(Test-Path -LiteralPath $taskDlltool){
        $taskSep=[char]0x1f
        $taskLinker=Join-Path $taskToolchainBin 'rust-lld.exe'
        # Direct LLD combines raw-dylib descriptors from chrono and windows-sys.
        # The bundled GNU driver ignores -fuse-ld=lld and omits TLS imports.
        $env:CARGO_ENCODED_RUSTFLAGS="-C${taskSep}dlltool=$taskDlltool${taskSep}-C${taskSep}linker=$taskLinker${taskSep}-C${taskSep}linker-flavor=ld.lld${taskSep}-C${taskSep}link-self-contained=yes"
    }
    & $taskLocalCargo @CargoArgs
} else {
    & cargo @CargoArgs
}
exit $LASTEXITCODE
