param([Parameter(Mandatory=$true)][string]$SourceCommit,[string]$Version='0.3.0',[Parameter(Mandatory=$true)][string]$BuildProof)
$ErrorActionPreference='Stop'
if($SourceCommit -notmatch '^[0-9a-f]{40}$' -or $Version -notmatch '^\d+\.\d+\.\d+(-[a-zA-Z0-9]+)?$'){throw 'Explicit source SHA and safe version are required.'}
$taskRoot=Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $taskRoot
$taskHead=(& git rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $taskHead -cne $SourceCommit){throw 'HEAD must equal SourceCommit.'}
$taskScope=@('src','static','templates','tools','tests','fixtures','docs','README.md','LICENSE','NOTICE','Cargo.toml','Cargo.lock','rust-toolchain.toml','.gitattributes')
$taskDirty=@(& git status --porcelain --untracked-files=all -- @taskScope)
if($LASTEXITCODE -ne 0 -or $taskDirty.Count){throw 'Production and packaging inputs must be committed and clean.'}
$taskLocalPrefix=[IO.Path]::GetFullPath((Join-Path $taskRoot '.local')).TrimEnd('\')+'\'
function Assert-PrivatePath([string]$Path){
    $taskFull=[IO.Path]::GetFullPath($Path)
    if(-not $taskFull.StartsWith($taskLocalPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Build proof paths must remain inside project .local.'}
    return $taskFull
}
$taskProofPath=Assert-PrivatePath $BuildProof
$taskProof=Get-Content -LiteralPath $taskProofPath -Raw | ConvertFrom-Json
if($taskProof.schema_version -ne 1 -or $taskProof.source_commit -cne $SourceCommit -or $taskProof.profile -cne 'release' -or $taskProof.build_exit -ne 0 -or -not $taskProof.rustc_version -or -not $taskProof.cargo_version){throw 'Successful frozen release proof for this commit required.'}
if($taskProof.tests_requested -and $taskProof.test_exit -ne 0){throw 'Requested frozen tests did not pass.'}
$taskFrozen=Assert-PrivatePath $taskProof.source_directory
$taskExecutable=Assert-PrivatePath $taskProof.executable_path
$taskArchive=Assert-PrivatePath $taskProof.source_archive
if((Get-FileHash -LiteralPath $taskExecutable).Hash -cne $taskProof.executable_sha256 -or (Get-FileHash -LiteralPath $taskArchive).Hash -cne $taskProof.source_archive_sha256 -or (Get-FileHash -LiteralPath (Join-Path $taskFrozen 'Cargo.lock')).Hash -cne $taskProof.cargo_lock_sha256){throw 'Build artifacts no longer match proof.'}
$taskActual=@(Get-ChildItem -LiteralPath $taskFrozen -File -Recurse)
if($taskActual.Count -ne @($taskProof.source_files).Count){throw 'Frozen source file count changed.'}
foreach($taskFile in $taskProof.source_files){
    $taskPath=[IO.Path]::GetFullPath((Join-Path $taskFrozen $taskFile.path))
    if(-not $taskPath.StartsWith($taskFrozen.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe source manifest path.'}
    if((Get-FileHash -LiteralPath $taskPath).Hash -cne $taskFile.sha256 -or (Get-Item -LiteralPath $taskPath).Length -ne $taskFile.bytes){throw "Frozen source changed: $($taskFile.path)"}
}
$taskPgSource=Join-Path $taskRoot '.local/postgres18/pgsql'
foreach($taskRequired in @('static','docs','fixtures','README.md','LICENSE','NOTICE','Cargo.lock','tools/setup-postgres.ps1','tools/start-packaged.ps1','tools/database-backup.ps1','tools/oracle')){if(-not (Test-Path -LiteralPath (Join-Path $taskFrozen $taskRequired))){throw "Missing frozen packaging input: $taskRequired"}}
foreach($taskRequired in @('bin','lib','share','server_license.txt','commandlinetools_3rd_party_licenses.txt')){if(-not (Test-Path -LiteralPath (Join-Path $taskPgSource $taskRequired))){throw "Missing PostgreSQL runtime input: $taskRequired"}}
$taskCargoText=Get-Content -LiteralPath (Join-Path $taskFrozen 'Cargo.toml') -Raw
$taskPackageSection=[regex]::Match($taskCargoText,'(?ms)^\[package\]\s*\r?\n(?<body>.*?)(?=^\[|\z)')
$taskVersionMatch=[regex]::Match($taskPackageSection.Groups['body'].Value,'(?m)^\s*version\s*=\s*"(?<version>[^"\r\n]+)"\s*(?:#.*)?$')
if(-not $taskPackageSection.Success -or -not $taskVersionMatch.Success -or $Version -cne $taskVersionMatch.Groups['version'].Value -or $Version -cne $taskProof.package_version){throw 'Package version must exactly match frozen Cargo package.version and build proof.'}
$taskName="process-intelligence-rs-$Version-windows-x86_64"
$taskDist=Join-Path $taskRoot '.local/dist'
$taskPackage=Join-Path $taskDist $taskName
if(Test-Path -LiteralPath $taskPackage){throw 'Package directory already exists. Use a new candidate version.'}
$taskZip=Join-Path $taskDist ($taskName+'.zip')
if(Test-Path -LiteralPath $taskZip){throw 'ZIP already exists.'}
New-Item -ItemType Directory -Path $taskPackage -Force|Out-Null
Copy-Item -LiteralPath $taskExecutable -Destination (Join-Path $taskPackage 'process-intelligence-rs.exe')
foreach($taskDirectory in @('static','docs','fixtures')){Copy-Item -LiteralPath (Join-Path $taskFrozen $taskDirectory) -Destination (Join-Path $taskPackage $taskDirectory) -Recurse}
foreach($taskFile in @('README.md','LICENSE','NOTICE','Cargo.lock')){if(Test-Path -LiteralPath (Join-Path $taskFrozen $taskFile)){Copy-Item -LiteralPath (Join-Path $taskFrozen $taskFile) -Destination $taskPackage}}
New-Item -ItemType Directory -Path (Join-Path $taskPackage 'tools') -Force|Out-Null
foreach($taskFile in @('setup-postgres.ps1','start-packaged.ps1','database-backup.ps1')){Copy-Item -LiteralPath (Join-Path $taskFrozen ('tools/'+$taskFile)) -Destination (Join-Path $taskPackage 'tools')}
Copy-Item -LiteralPath (Join-Path $taskFrozen 'tools/oracle') -Destination (Join-Path $taskPackage 'tools/oracle') -Recurse
[IO.File]::WriteAllText((Join-Path $taskPackage 'Start.ps1'),"param([int]`$Port=3000,[int]`$PostgresPort=5433)`r`n& (Join-Path `$PSScriptRoot 'tools/start-packaged.ps1') -Port `$Port -PostgresPort `$PostgresPort`r`nexit `$LASTEXITCODE`r`n")
$taskPgSource=Join-Path $taskRoot '.local/postgres18/pgsql'
$taskPgTarget=Join-Path $taskPackage 'runtime/postgresql/pgsql'
New-Item -ItemType Directory -Path $taskPgTarget -Force|Out-Null
foreach($taskDirectory in @('bin','lib','share')){Copy-Item -LiteralPath (Join-Path $taskPgSource $taskDirectory) -Destination (Join-Path $taskPgTarget $taskDirectory) -Recurse}
foreach($taskFile in @('server_license.txt','commandlinetools_3rd_party_licenses.txt')){Copy-Item -LiteralPath (Join-Path $taskPgSource $taskFile) -Destination $taskPgTarget}
$taskFiles=@(Get-ChildItem -LiteralPath $taskPackage -File -Recurse|Sort-Object FullName|ForEach-Object{@{path=$_.FullName.Substring($taskPackage.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName).Hash;bytes=$_.Length}})
@{version=$Version;source_commit=$SourceCommit;platform='windows-x86_64';build_proof=@{schema_version=1;source_archive_sha256=$taskProof.source_archive_sha256;executable_sha256=$taskProof.executable_sha256;cargo_lock_sha256=$taskProof.cargo_lock_sha256;profile=$taskProof.profile;build_exit=$taskProof.build_exit;tests_requested=$taskProof.tests_requested;test_exit=$taskProof.test_exit;cargo_version=$taskProof.cargo_version;rustc_version=$taskProof.rustc_version;rustup_toolchain=$taskProof.rustup_toolchain};postgres_version='18.6';postgres_archive_first_observed_sha256='E2246BA91D22345BC3D017586C09EDE52D9DF180B1EEB480F050445F1CAD84E2';files=$taskFiles}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $taskPackage 'build-manifest.json') -Encoding utf8
$taskZip=Join-Path $taskDist ($taskName+'.zip')
if(Test-Path -LiteralPath $taskZip){throw 'ZIP already exists.'}
Compress-Archive -LiteralPath $taskPackage -DestinationPath $taskZip -CompressionLevel Optimal
Write-Output "Package: $taskZip"
Write-Output "SHA256: $((Get-FileHash -LiteralPath $taskZip).Hash)"
