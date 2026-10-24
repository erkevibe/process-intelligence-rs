param(
    [ValidateSet('Backup','Restore')][string]$Mode='Backup',
    [Parameter(Mandatory=$true)][string]$BackupFile,
    [string]$Database='process_intelligence',
    [string]$TargetDatabase,
    [string]$PrivateConfig,
    [string]$PostgresBin
)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
if(!$PrivateConfig){$PrivateConfig=Join-Path $taskRoot '.local/postgres-private.json'}
if(!$PostgresBin){$PostgresBin=if(Test-Path -LiteralPath (Join-Path $taskRoot 'runtime/postgresql/pgsql/bin/pg_dump.exe')){Join-Path $taskRoot 'runtime/postgresql/pgsql/bin'}else{Join-Path $taskRoot '.local/postgres18/pgsql/bin'}}
if($Database -cnotmatch '^[a-z][a-z0-9_]{0,62}$'){throw 'Invalid source database identifier.'}
$taskDestination=[IO.Path]::GetFullPath($BackupFile)
$taskPrivateBoundary=[IO.Path]::GetFullPath((Join-Path $taskRoot '.local')).TrimEnd([char[]]'\/')
$taskPrivateRoot=$taskPrivateBoundary+[IO.Path]::DirectorySeparatorChar
$taskPathComparison=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
if(!$taskDestination.StartsWith($taskPrivateRoot,$taskPathComparison)){throw 'Store private database archives inside this installation .local directory.'}
$taskManifestPath=$taskDestination+'.manifest.json'
function Assert-TaskArchiveComponents([string]$Path) {
    # Check .local itself and every existing descendant, including both leaves.
    # This is a static check, not an atomic guard against another local writer.
    $taskComponents=@($taskPrivateBoundary)
    $taskCursor=$taskPrivateBoundary
    foreach($taskPart in $Path.Substring($taskPrivateBoundary.Length).TrimStart([char[]]'\/').Split([char[]]'\/',[StringSplitOptions]::RemoveEmptyEntries)){
        $taskCursor=Join-Path $taskCursor $taskPart
        $taskComponents+=,$taskCursor
    }
    for($taskIndex=0;$taskIndex -lt $taskComponents.Count;$taskIndex++){
        try {$taskAttributes=[IO.File]::GetAttributes($taskComponents[$taskIndex])}
        catch {
            $taskCause=$_.Exception
            if($taskCause.InnerException){$taskCause=$taskCause.InnerException}
            if($taskCause -is [IO.FileNotFoundException] -or $taskCause -is [IO.DirectoryNotFoundException]){continue}
            throw
        }
        if($taskAttributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe archive path: links and reparse points inside installation .local are not allowed.'}
        if($taskIndex -lt $taskComponents.Count-1 -and -not ($taskAttributes -band [IO.FileAttributes]::Directory)){throw 'Archive parent must be a directory.'}
        if($taskIndex -eq $taskComponents.Count-1 -and ($taskAttributes -band [IO.FileAttributes]::Directory)){throw 'Archive and manifest targets must be regular files.'}
    }
}
Assert-TaskArchiveComponents $taskDestination
Assert-TaskArchiveComponents $taskManifestPath
if($Mode -eq 'Backup'){
    if((Test-Path -LiteralPath $taskDestination) -or (Test-Path -LiteralPath $taskManifestPath)){throw 'Backup archive or manifest already exists; choose a new filename.'}
}else{
    if($TargetDatabase -cnotmatch '^pi_restore_[a-z0-9_]{1,50}$' -or $TargetDatabase -eq $Database){throw 'Restore requires a NEW pi_restore_* database, never the source database.'}
    if(!(Test-Path -LiteralPath $taskDestination -PathType Leaf) -or !(Test-Path -LiteralPath $taskManifestPath -PathType Leaf)){throw 'Restore requires an existing regular archive and manifest.'}
}
$taskParent=Split-Path -Parent $taskDestination
New-Item -ItemType Directory -Path $taskParent -Force|Out-Null
Assert-TaskArchiveComponents $taskDestination
Assert-TaskArchiveComponents $taskManifestPath
$taskRules=New-Object Security.AccessControl.DirectorySecurity
$taskRules.SetAccessRuleProtection($true,$false)
$taskRules.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().Name,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
$taskDirectory=[IO.DirectoryInfo]::new($taskParent)
if($taskDirectory.PSObject.Methods['SetAccessControl']){$taskDirectory.SetAccessControl($taskRules)}else{[IO.FileSystemAclExtensions]::SetAccessControl($taskDirectory,$taskRules)}
$taskConfig=Get-Content -LiteralPath $PrivateConfig -Raw|ConvertFrom-Json
$taskPreviousPassword=$env:PGPASSWORD
try {
    $env:PGPASSWORD=$taskConfig.admin_password
    $taskConnection=@('-h','127.0.0.1','-p',[string]$taskConfig.port,'-U','pi_admin','-w')
    if($Mode -eq 'Backup'){
        if((Test-Path -LiteralPath $taskDestination) -or (Test-Path -LiteralPath $taskManifestPath)){throw 'Backup archive or manifest already exists; choose a new filename.'}
        & (Join-Path $PostgresBin 'pg_dump.exe') @taskConnection -d $Database -Fc -f $taskDestination
        if($LASTEXITCODE -ne 0){throw 'Backup failed; do not use the partial archive.'}
        $taskManifest=@{format='postgres_custom';database=$Database;sha256=(Get-FileHash -LiteralPath $taskDestination -Algorithm SHA256).Hash;size=(Get-Item -LiteralPath $taskDestination).Length;created_utc=[DateTime]::UtcNow.ToString('o');includes_auth=$true}
        $taskManifest|ConvertTo-Json|Set-Content -LiteralPath $taskManifestPath -Encoding utf8
        Write-Output 'Database-level backup created. Validate restore in a new isolated database before relying on it.'
    }else{
        $taskManifest=Get-Content -LiteralPath $taskManifestPath -Raw|ConvertFrom-Json
        if($taskManifest.format -ne 'postgres_custom' -or (Get-FileHash -LiteralPath $taskDestination -Algorithm SHA256).Hash -cne $taskManifest.sha256 -or (Get-Item -LiteralPath $taskDestination).Length -ne $taskManifest.size){throw 'Backup integrity check failed.'}
        $taskCount=& (Join-Path $PostgresBin 'psql.exe') @taskConnection -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$TargetDatabase'"
        if($LASTEXITCODE -ne 0 -or $taskCount.Trim() -ne '0'){throw 'Restore target exists or could not be checked; it is not changed.'}
        & (Join-Path $PostgresBin 'psql.exe') @taskConnection -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $TargetDatabase OWNER pi_app;"
        if($LASTEXITCODE -ne 0){throw 'New restore database creation failed.'}
        & (Join-Path $PostgresBin 'pg_restore.exe') @taskConnection -d $TargetDatabase --exit-on-error --single-transaction --no-owner --no-privileges --role=pi_app $taskDestination
        if($LASTEXITCODE -ne 0){throw 'Restore failed; new target is not ready. Source database is unchanged; inspect the retained target.'}
        Write-Output 'Archive restored atomically into the new database. Check exports and access before using it.'
    }
}finally{$env:PGPASSWORD=$taskPreviousPassword;$taskConfig=$null}
