param([Parameter(Mandatory=$true)][string]$SourceCommit,[switch]$RunTests)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $taskRoot
if($SourceCommit -cnotmatch '^[0-9a-f]{40}$'){throw 'Explicit lowercase 40-character source commit required.'}
$taskHead=(& git rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $taskHead -cne $SourceCommit){throw 'HEAD must equal SourceCommit.'}
$taskScope=@('src','static','templates','tools','tests','fixtures','docs','README.md','LICENSE','NOTICE','Cargo.toml','Cargo.lock','rust-toolchain.toml','.gitattributes')
$taskDirty=@(& git status --porcelain --untracked-files=all -- @taskScope)
if($LASTEXITCODE -ne 0 -or $taskDirty.Count){throw 'Production, tests, assets and build inputs must be committed and clean.'}
$taskId=[Guid]::NewGuid().ToString('N')
$taskFrozen=Join-Path $taskRoot ".local/frozen-$taskId"
$taskTarget=Join-Path $taskRoot ".local/build-$taskId"
$taskArchive=Join-Path $taskRoot ".local/frozen-$taskId.zip"
$taskProof=Join-Path $taskRoot ".local/build-$taskId-proof.json"
foreach($taskPath in @($taskFrozen,$taskTarget,$taskArchive,$taskProof)){if(Test-Path -LiteralPath $taskPath){throw 'Fresh build path already exists.'}}
& git archive --format=zip --output=$taskArchive $SourceCommit
if($LASTEXITCODE -ne 0){throw 'Git archive failed.'}
Expand-Archive -LiteralPath $taskArchive -DestinationPath $taskFrozen
function Get-SourceInventory([string]$Directory){
    @(Get-ChildItem -LiteralPath $Directory -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{path=$_.FullName.Substring($Directory.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash;bytes=$_.Length}
    })
}
$taskBefore=Get-SourceInventory $taskFrozen
$taskManifest=Join-Path $taskFrozen 'Cargo.toml'
$taskCargoText=Get-Content -LiteralPath $taskManifest -Raw
$taskPackageSection=[regex]::Match($taskCargoText,'(?ms)^\[package\]\s*\r?\n(?<body>.*?)(?=^\[|\z)')
$taskVersionMatch=[regex]::Match($taskPackageSection.Groups['body'].Value,'(?m)^\s*version\s*=\s*"(?<version>[^"\r\n]+)"\s*(?:#.*)?$')
if(-not $taskPackageSection.Success -or -not $taskVersionMatch.Success){throw 'Literal frozen Cargo package.version required.'}
$taskPackageVersion=$taskVersionMatch.Groups['version'].Value
$taskLog=Join-Path $taskRoot ".local/build-$taskId.log"
Set-Location -LiteralPath $taskFrozen
& (Join-Path $PSScriptRoot 'cargo.ps1') -CargoArgs @('build','--locked','--release','--manifest-path',$taskManifest,'--target-dir',$taskTarget) *> $taskLog
$taskBuildExit=$LASTEXITCODE
if($taskBuildExit -ne 0){throw "Frozen release build failed: exit $taskBuildExit; log $taskLog"}
$taskTestExit=$null
$taskTestLog=$null
if($RunTests){
    $taskTestLog=Join-Path $taskRoot ".local/build-$taskId-tests.log"
    & (Join-Path $PSScriptRoot 'cargo.ps1') -CargoArgs @('test','--locked','--tests','--manifest-path',$taskManifest,'--target-dir',$taskTarget) *> $taskTestLog
    $taskTestExit=$LASTEXITCODE
    if($taskTestExit -ne 0){throw "Frozen tests failed: exit $taskTestExit; log $taskTestLog"}
}
$taskAfter=Get-SourceInventory $taskFrozen
if(($taskBefore | ConvertTo-Json -Depth 5 -Compress) -cne ($taskAfter | ConvertTo-Json -Depth 5 -Compress)){throw 'Frozen source changed during build.'}
$taskExe=Join-Path $taskTarget 'release/process-intelligence-rs.exe'
if(-not (Test-Path -LiteralPath $taskExe -PathType Leaf)){throw 'Release executable missing.'}
$taskCargoVersion=(& (Join-Path $PSScriptRoot 'cargo.ps1') -CargoArgs @('--version','--verbose') | Out-String).Trim()
if($LASTEXITCODE -ne 0){throw 'Cargo version probe failed.'}
$taskRustc=Join-Path $taskRoot '.local/cargo/bin/rustc.exe'
if(-not (Test-Path -LiteralPath $taskRustc)){throw 'Local toolchain required for build proof.'}
$taskRustVersion=(& $taskRustc --version --verbose | Out-String).Trim()
if($LASTEXITCODE -ne 0){throw 'Rust compiler version probe failed.'}
[ordered]@{schema_version=1;package_version=$taskPackageVersion;source_commit=$SourceCommit;source_directory=$taskFrozen;source_archive=$taskArchive;source_archive_sha256=(Get-FileHash -LiteralPath $taskArchive).Hash;source_files=$taskAfter;executable_path=$taskExe;executable_sha256=(Get-FileHash -LiteralPath $taskExe).Hash;cargo_lock_sha256=(Get-FileHash -LiteralPath (Join-Path $taskFrozen 'Cargo.lock')).Hash;profile='release';build_exit=$taskBuildExit;tests_requested=[bool]$RunTests;test_exit=$taskTestExit;build_log=$taskLog;test_log=$taskTestLog;cargo_version=$taskCargoVersion;rustc_version=$taskRustVersion;rustup_toolchain=$env:RUSTUP_TOOLCHAIN;rustflags=$env:CARGO_ENCODED_RUSTFLAGS;completed_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $taskProof -Encoding utf8
Write-Output "Build proof: $taskProof"
