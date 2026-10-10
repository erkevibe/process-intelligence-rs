param()
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskPrivate=Join-Path $taskRoot '.local'
$taskBin=Join-Path $taskPrivate 'bin'
New-Item -ItemType Directory -Path $taskBin -Force | Out-Null
$taskAccount=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $taskPrivate /inheritance:r /grant:r "${taskAccount}:(OI)(CI)F" | Out-Null
if($LASTEXITCODE -ne 0){ throw 'Cannot restrict the local toolchain directory.' }
function Get-VerifiedFile($Uri,$Path,$ExpectedHash){
    if(!(Test-Path -LiteralPath $Path)) { Invoke-WebRequest -Uri $Uri -OutFile $Path }
    $taskActual=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if($taskActual -ne $ExpectedHash){ throw "Checksum mismatch for $Path. Remove this file and retry from the documented official source." }
}
$taskInit=Join-Path $taskBin 'rustup-init.exe'
Get-VerifiedFile 'https://win.rustup.rs/x86_64' $taskInit '6F4BEF66261261FCB43131BE8720BAB817D403A09EDEC7455C371974B90BDB7E'
$env:CARGO_HOME=Join-Path $taskPrivate 'cargo'
$env:RUSTUP_HOME=Join-Path $taskPrivate 'rustup'
$taskCargo=Join-Path $env:CARGO_HOME 'bin\cargo.exe'
if(!(Test-Path -LiteralPath $taskCargo)){
    & $taskInit -y --no-modify-path --profile minimal --default-toolchain 1.99.0-x86_64-pc-windows-gnu
    if($LASTEXITCODE -ne 0){throw 'Rust installation failed.'}
} else {
    & (Join-Path $env:CARGO_HOME 'bin\rustup.exe') toolchain install 1.99.0-x86_64-pc-windows-gnu --profile minimal
    if($LASTEXITCODE -ne 0){throw 'Pinned Rust installation failed.'}
}
& (Join-Path $env:CARGO_HOME 'bin\rustup.exe') component add rustfmt clippy --toolchain 1.99.0-x86_64-pc-windows-gnu
if($LASTEXITCODE -ne 0){throw 'Rust components installation failed.'}
$taskArchive=Join-Path $taskBin 'llvm-mingw.zip'
Get-VerifiedFile 'https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/llvm-mingw-20261006-ucrt-x86_64.zip' $taskArchive '317492C456AA27EE607A5919F1D2D38DCDC1112516A24D0BF4B00D078F52D17A'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$taskZip=[System.IO.Compression.ZipFile]::OpenRead($taskArchive)
try {
    foreach($taskFile in @('llvm-dlltool.exe','libLLVM-23.dll','libc++.dll','libunwind.dll','libwinpthread-1.dll')) {
        # Select the host x86_64 runtime, never an ARM/i686 target DLL.
        $taskEntry=$taskZip.GetEntry('llvm-mingw-20261006-ucrt-x86_64/bin/'+$taskFile)
        if(!$taskEntry){throw "Missing archive entry: $taskFile"}
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($taskEntry,(Join-Path $taskBin $taskFile),$true)
    }
} finally {$taskZip.Dispose()}
$taskProbeDef=Join-Path $taskPrivate 'setup-probe.def'
$taskProbeLib=Join-Path $taskPrivate 'setup-probe.lib'
Set-Content -LiteralPath $taskProbeDef -Encoding ascii -Value "LIBRARY bcryptprimitives.dll`nEXPORTS`nProcessPrng"
& (Join-Path $taskBin 'llvm-dlltool.exe') -m i386:x86-64 -d $taskProbeDef -l $taskProbeLib
if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $taskProbeLib)){throw 'Host LLVM import-library probe failed.'}
& (Join-Path $PSScriptRoot 'cargo.ps1') --version
if($LASTEXITCODE -ne 0){throw 'Cargo probe failed.'}
Write-Output 'Project-local toolchain ready. Global PATH and global Rust settings were not changed.'
