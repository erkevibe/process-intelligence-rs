param([int]$Port=5433)
$ErrorActionPreference='Stop'
if($Port -lt 1 -or $Port -gt 65535){throw 'PostgreSQL port must be between 1 and 65535.'}
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskLocal=Join-Path $taskRoot '.local'
New-Item -ItemType Directory -Path $taskLocal -Force|Out-Null
$taskIdentity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskAcl=New-Object Security.AccessControl.DirectorySecurity
$taskAcl.SetAccessRuleProtection($true,$false)
$taskAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($taskIdentity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
# Persist only the modified access section. Set-Acl may also request SACL
# privileges when applying a fresh descriptor on a newly extracted folder.
$taskPrivateDirectory=[IO.DirectoryInfo]::new($taskLocal)
if($taskPrivateDirectory.PSObject.Methods['SetAccessControl']){
    $taskPrivateDirectory.SetAccessControl($taskAcl)
}else{
    [IO.FileSystemAclExtensions]::SetAccessControl($taskPrivateDirectory,$taskAcl)
}
$taskPrivateAcl=Get-Acl -LiteralPath $taskLocal
if(!$taskPrivateAcl.AreAccessRulesProtected -or $taskPrivateAcl.Access.Count -ne 1 -or $taskPrivateAcl.Access[0].IsInherited -or $taskPrivateAcl.Access[0].AccessControlType -ne 'Allow' -or $taskPrivateAcl.Access[0].FileSystemRights -ne 'FullControl' -or $taskPrivateAcl.Access[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Private data directory access protection failed'}
New-Item -ItemType Directory -Path (Join-Path $taskLocal 'logs') -Force|Out-Null
$taskBootstrapLock=$null
$taskPreviousPgPassword=$env:PGPASSWORD
try {
try {$taskBootstrapLock=[IO.File]::Open((Join-Path $taskLocal 'postgres-bootstrap.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Another bootstrap is running. Existing data is preserved.'}
$taskArchive=Join-Path $taskLocal 'postgresql-18.6-windows-x64.zip'
$taskHash='E2246BA91D22345BC3D017586C09EDE52D9DF180B1EEB480F050445F1CAD84E2'
$taskPgRoot=Join-Path $taskLocal 'postgres18'
if(Test-Path -LiteralPath (Join-Path $taskRoot 'runtime/postgresql/pgsql/bin/postgres.exe')){$taskPgRoot=Join-Path $taskRoot 'runtime/postgresql'}
if(!(Test-Path -LiteralPath (Join-Path $taskPgRoot 'pgsql/bin/postgres.exe'))){
    if(!(Test-Path -LiteralPath $taskArchive)){Invoke-WebRequest 'https://sbp.enterprisedb.com/getfile.jsp?fileid=1260609' -OutFile $taskArchive}
    if((Get-FileHash -LiteralPath $taskArchive).Hash -ne $taskHash){throw 'PostgreSQL distribution hash differs from pinned first-observed official artifact'}
    Expand-Archive -LiteralPath $taskArchive -DestinationPath $taskPgRoot
}elseif(Test-Path -LiteralPath $taskArchive){
    if((Get-FileHash -LiteralPath $taskArchive).Hash -ne $taskHash){throw 'PostgreSQL distribution hash differs from pinned first-observed official artifact'}
}
$taskPgBin=Join-Path $taskPgRoot 'pgsql/bin'
& (Join-Path $taskPgBin 'postgres.exe') --version
if($LASTEXITCODE -ne 0){throw 'PostgreSQL executable probe failed'}
$taskData=Join-Path $taskLocal 'pgdata'
$taskConfig=Join-Path $taskLocal 'postgres-private.json'
$taskPending=Join-Path $taskLocal 'postgres-private.pending.json'
$taskPwfile=Join-Path $taskLocal 'pg-init-password.txt'
$taskSql=Join-Path $taskLocal 'pg-bootstrap-private.sql'
$taskHasCluster=Test-Path -LiteralPath (Join-Path $taskData 'PG_VERSION')
if((Test-Path -LiteralPath $taskConfig) -and !$taskHasCluster){throw 'Completed private configuration exists but the initialized cluster is missing. Files preserved; restore its database backup into a separate directory. Automatic reinitialization is refused.'}
if((Test-Path -LiteralPath $taskConfig) -and (Test-Path -LiteralPath $taskPending)){throw 'Both completed and pending configurations exist. Files preserved; inspect their matching backup before continuing.'}
if(!(Test-Path -LiteralPath $taskConfig) -and !(Test-Path -LiteralPath $taskPending)){
    if($taskHasCluster -or ((Test-Path -LiteralPath $taskData) -and @(Get-ChildItem -LiteralPath $taskData -Force).Count -gt 0)){throw 'Existing or incomplete cluster has no recognized private configuration. Data preserved. Recover the matching private configuration or a database backup into a separate directory; do not delete or reinitialize this cluster.'}
    $taskAdminPassword=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
    $taskAppPassword=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
    $taskStaged=@{bootstrap_version=1;cluster_path=[IO.Path]::GetFullPath($taskData);port=$Port;admin_password=$taskAdminPassword;database_url="host=127.0.0.1 port=$Port user=pi_app password=$taskAppPassword dbname=process_intelligence connect_timeout=5";app_password=$taskAppPassword}|ConvertTo-Json
    $taskStageBytes=[Text.Encoding]::UTF8.GetBytes($taskStaged)
    $taskStageFile=[IO.File]::Open($taskPending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$taskStageFile.Write($taskStageBytes,0,$taskStageBytes.Length);$taskStageFile.Flush($true)}finally{$taskStageFile.Dispose();$taskStaged=$null;$taskStageBytes=$null}
    Write-Output 'Bootstrap credentials staged privately before cluster initialization.'
}
$taskSecretPath=if(Test-Path -LiteralPath $taskConfig){$taskConfig}else{$taskPending}
try{$taskSecrets=Get-Content -LiteralPath $taskSecretPath -Raw|ConvertFrom-Json}catch{throw 'Private configuration is unreadable. Existing files preserved; recover its matching backup.'}
if($taskSecrets.port -ne $Port -or $taskSecrets.admin_password -cnotmatch '^[a-f0-9]{64}$' -or $taskSecrets.app_password -cnotmatch '^[a-f0-9]{64}$' -or $taskSecrets.database_url -cne "host=127.0.0.1 port=$Port user=pi_app password=$($taskSecrets.app_password) dbname=process_intelligence connect_timeout=5"){throw 'Private configuration does not match this launch. Use its original port or matching backup; existing data preserved.'}
if($taskSecretPath -eq $taskPending -and ($taskSecrets.bootstrap_version -ne 1 -or $taskSecrets.cluster_path -cne [IO.Path]::GetFullPath($taskData))){throw 'Staged bootstrap belongs to an unknown cluster. Existing data preserved.'}
if(!$taskHasCluster){
    if((Test-Path -LiteralPath $taskData) -and @(Get-ChildItem -LiteralPath $taskData -Force).Count -gt 0){throw 'Interrupted initdb left an incomplete directory. Existing files and staged credentials preserved; inspect or recover to a separate directory.'}
    [IO.File]::WriteAllText($taskPwfile,$taskSecrets.admin_password)
    & (Join-Path $taskPgBin 'initdb.exe') -D $taskData -U pi_admin -A scram-sha-256 --pwfile=$taskPwfile --encoding=UTF8 --locale=C
    if($LASTEXITCODE -ne 0){throw 'initdb failed'}
    Remove-Item -LiteralPath $taskPwfile
}
if((Get-Content -LiteralPath (Join-Path $taskData 'PG_VERSION') -Raw).Trim() -ne '18'){throw 'Unsupported existing PostgreSQL data version. Files preserved.'}
if($taskSecretPath -eq $taskPending){
    $taskServerConfig=Join-Path $taskData 'postgresql.conf'
    $taskServerText=Get-Content -LiteralPath $taskServerConfig -Raw
    $taskManagedBlock="`n# PI_LOCAL_BOOTSTRAP_V1`nlisten_addresses = '127.0.0.1'`nport = $Port`n# PI_LOCAL_BOOTSTRAP_END`n"
    if($taskServerText -match '(?m)^# PI_LOCAL_BOOTSTRAP_V1$'){
        if(!$taskServerText.EndsWith($taskManagedBlock,[StringComparison]::Ordinal)){throw 'Staged server configuration is inconsistent. Existing files preserved.'}
    }else{
        $taskConfigTemporary=Join-Path $taskData 'postgresql.conf.pi-bootstrap.tmp'
        $taskServerBytes=[Text.Encoding]::UTF8.GetBytes($taskServerText+$taskManagedBlock)
        $taskConfStream=[IO.File]::Open($taskConfigTemporary,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$taskConfStream.Write($taskServerBytes,0,$taskServerBytes.Length);$taskConfStream.Flush($true)}finally{$taskConfStream.Dispose()}
        # Native Windows PowerShell 5 converts a null string argument to an empty
        # backup path. Retain an explicit private pre-bootstrap backup instead.
        $taskServerConfigBackup=Join-Path $taskData 'postgresql.conf.pi-before-bootstrap'
        [IO.File]::Replace($taskConfigTemporary,$taskServerConfig,$taskServerConfigBackup)
    }
    [IO.File]::Move($taskPending,$taskConfig)
    Write-Output 'Recognized initialized cluster configuration finalized.'
}
& (Join-Path $taskPgBin 'pg_ctl.exe') -D $taskData status
if($LASTEXITCODE -ne 0){
    # Wait for pg_ctl itself, not its long-lived PostgreSQL process tree or inherited pipe.
    $taskStart=Start-Process -FilePath (Join-Path $taskPgBin 'pg_ctl.exe') -ArgumentList @('-D',('"'+$taskData+'"'),'-l',('"'+(Join-Path $taskLocal 'logs/postgres-server.log')+'"'),'-w','start') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskLocal 'logs/pg-start.out') -RedirectStandardError (Join-Path $taskLocal 'logs/pg-start.err')
    # Windows PowerShell 5 needs the process handle retained before waiting;
    # otherwise an exited PassThru process can expose a null ExitCode.
    $taskStartHandle=$taskStart.Handle
    if(!$taskStart.WaitForExit(30000) -or $taskStart.ExitCode -ne 0){throw 'PostgreSQL server start failed'}
}
$env:PGPASSWORD=$taskSecrets.admin_password
try{
    $taskExisting=& (Join-Path $taskPgBin 'psql.exe') -h 127.0.0.1 -p $taskSecrets.port -U pi_admin -d postgres -tAc "SELECT count(*) FROM pg_roles WHERE rolname='pi_app'"
    if($LASTEXITCODE -ne 0){throw 'Admin connectivity probe failed'}
    if($taskExisting.Trim() -eq '0'){
        $taskSql=Join-Path $taskLocal 'pg-bootstrap-private.sql'
        [IO.File]::WriteAllText($taskSql,"CREATE ROLE pi_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$($taskSecrets.app_password)';")
        & (Join-Path $taskPgBin 'psql.exe') -h 127.0.0.1 -p $taskSecrets.port -U pi_admin -d postgres -v ON_ERROR_STOP=1 -f $taskSql
        if($LASTEXITCODE -ne 0){throw 'Application database bootstrap failed'}
        Remove-Item -LiteralPath $taskSql
    }
    $taskDatabaseExists=& (Join-Path $taskPgBin 'psql.exe') -h 127.0.0.1 -p $taskSecrets.port -U pi_admin -d postgres -w -tAc "SELECT count(*) FROM pg_database WHERE datname='process_intelligence'"
    if($LASTEXITCODE -ne 0){throw 'Database existence probe failed'}
    if($taskDatabaseExists.Trim() -eq '0'){
        & (Join-Path $taskPgBin 'psql.exe') -h 127.0.0.1 -p $taskSecrets.port -U pi_admin -d postgres -w -v ON_ERROR_STOP=1 -c "CREATE DATABASE process_intelligence OWNER pi_app;"
        if($LASTEXITCODE -ne 0){throw 'Application database creation failed'}
    }
}finally{Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue}
$env:PGPASSWORD=$taskSecrets.app_password
try{
    & (Join-Path $taskPgBin 'psql.exe') -h 127.0.0.1 -p $taskSecrets.port -U pi_app -d process_intelligence -v ON_ERROR_STOP=1 -c "BEGIN; CREATE TABLE IF NOT EXISTS bootstrap_probe(value integer); INSERT INTO bootstrap_probe VALUES(1); ROLLBACK; SELECT current_user, rolsuper FROM pg_roles WHERE rolname=current_user;"
    if($LASTEXITCODE -ne 0){throw 'App role transaction probe failed'}
}finally{Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue;$taskSecrets=$null;$taskAdminPassword=$null;$taskAppPassword=$null}
Write-Output "Project-local PostgreSQL ready on loopback port $Port. Credentials are private in .local."
} finally {
    foreach($taskTemporary in @($taskPwfile,$taskSql)){if($taskTemporary -and (Test-Path -LiteralPath $taskTemporary)){Remove-Item -LiteralPath $taskTemporary -ErrorAction SilentlyContinue}}
    $taskSecrets=$null;$taskAdminPassword=$null;$taskAppPassword=$null
    $env:PGPASSWORD=$taskPreviousPgPassword
    if($taskBootstrapLock){$taskBootstrapLock.Dispose()}
}
