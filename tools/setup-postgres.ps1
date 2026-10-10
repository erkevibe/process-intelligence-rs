param([int]$Port=5433)
$ErrorActionPreference='Stop'
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
if(!(Test-Path -LiteralPath (Join-Path $taskData 'PG_VERSION'))){
    $taskAdminPassword=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
    $taskAppPassword=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
    $taskPwfile=Join-Path $taskLocal 'pg-init-password.txt'
    [IO.File]::WriteAllText($taskPwfile,$taskAdminPassword)
    & (Join-Path $taskPgBin 'initdb.exe') -D $taskData -U pi_admin -A scram-sha-256 --pwfile=$taskPwfile --encoding=UTF8 --locale=C
    if($LASTEXITCODE -ne 0){throw 'initdb failed'}
    Remove-Item -LiteralPath $taskPwfile
    [IO.File]::AppendAllText((Join-Path $taskData 'postgresql.conf'),"`nlisten_addresses = '127.0.0.1'`nport = $Port`n")
    @{port=$Port;admin_password=$taskAdminPassword;database_url="host=127.0.0.1 port=$Port user=pi_app password=$taskAppPassword dbname=process_intelligence connect_timeout=5";app_password=$taskAppPassword}|ConvertTo-Json|Set-Content -LiteralPath $taskConfig -Encoding utf8
}
$taskSecrets=Get-Content -LiteralPath $taskConfig -Raw|ConvertFrom-Json
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
