param(
    [Parameter(Mandatory=$true)][string]$BackupFile,
    [string]$Database='process_intelligence',
    [string]$PrivateConfig
)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskLocal=[IO.Path]::GetFullPath((Join-Path $taskRoot '.local')).TrimEnd('\')+'\'
if(!$PrivateConfig){$PrivateConfig=Join-Path $taskLocal 'postgres-private.json'}
foreach($taskPath in @($PrivateConfig,$BackupFile)){
    if(![IO.Path]::GetFullPath($taskPath).StartsWith($taskLocal,[StringComparison]::OrdinalIgnoreCase)){throw 'Private configuration and backup must belong to this installation .local directory.'}
}
if($Database -cnotmatch '^(process_intelligence|pi_restore_[a-z0-9_]{1,50}|pi_s4_[a-z0-9_]{1,50})$'){throw 'Use the local database or an explicitly named isolated restore.'}
$taskManifest=Get-Content -LiteralPath (Join-Path $taskRoot 'build-manifest.json') -Raw|ConvertFrom-Json
foreach($taskFile in $taskManifest.files){
    $taskAbsolute=[IO.Path]::GetFullPath((Join-Path $taskRoot $taskFile.path))
    if(!$taskAbsolute.StartsWith($taskRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Manifest path is outside package.'}
    if(!(Test-Path -LiteralPath $taskAbsolute) -or (Get-FileHash -LiteralPath $taskAbsolute -Algorithm SHA256).Hash -cne $taskFile.sha256 -or (Get-Item -LiteralPath $taskAbsolute).Length -ne $taskFile.bytes){throw 'Package integrity check failed.'}
}
$taskBackup=Get-Content -LiteralPath ($BackupFile+'.manifest.json') -Raw|ConvertFrom-Json
if($taskBackup.format -ne 'postgres_custom' -or (Get-FileHash -LiteralPath $BackupFile -Algorithm SHA256).Hash -cne $taskBackup.sha256 -or (Get-Item -LiteralPath $BackupFile).Length -ne $taskBackup.size){throw 'Backup integrity check failed. Database is unchanged.'}
$taskDirectory=[IO.DirectoryInfo]::new((Split-Path -Parent ([IO.Path]::GetFullPath($PrivateConfig))))
$taskAcl=Get-Acl -LiteralPath $taskDirectory.FullName
$taskSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskRules=@($taskAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if(!$taskAcl.AreAccessRulesProtected -or $taskRules.Count -ne 1 -or $taskRules[0].IdentityReference.Value -ne $taskSid -or $taskRules[0].IsInherited -or $taskRules[0].AccessControlType -ne 'Allow' -or $taskRules[0].FileSystemRights -ne 'FullControl'){throw 'Private configuration directory must have current-user-only protected access.'}
$taskConfig=Get-Content -LiteralPath $PrivateConfig -Raw|ConvertFrom-Json
if($taskConfig.port -lt 1 -or $taskConfig.port -gt 65535 -or $taskConfig.app_password -cnotmatch '^[a-f0-9]{64}$' -or $taskConfig.database_url -cne "host=127.0.0.1 port=$($taskConfig.port) user=pi_app password=$($taskConfig.app_password) dbname=process_intelligence connect_timeout=5"){throw 'Unsupported private configuration. Existing data preserved.'}
$taskPriorUrl=$env:PI_DATABASE_URL
try {
    $env:PI_DATABASE_URL="host=127.0.0.1 port=$($taskConfig.port) user=pi_app password=$($taskConfig.app_password) dbname=$Database connect_timeout=5"
    Write-Output 'Offline forward-only migration. An active application will block this operation; no automatic reset or cleanup.'
    & (Join-Path $taskRoot 'process-intelligence-rs.exe') --migrate-storage
    $taskExit=$LASTEXITCODE
    if($taskExit -ne 0){throw 'Migration did not complete. Preserve logs and data; inspect the cause before resuming.'}
    Write-Output 'Storage migration completed. Check access and exports before using the upgraded copy.'
} finally {
    $env:PI_DATABASE_URL=$taskPriorUrl
    $taskConfig=$null
}
exit $taskExit
