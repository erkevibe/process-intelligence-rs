param(
    [ValidateSet('Preview','Apply')][string]$Mode='Preview',
    [Parameter(Mandatory=$true)][string]$BackupFile,
    [Parameter(Mandatory=$true)][string]$PlanFile,
    [string]$Database='process_intelligence',
    [Parameter(Mandatory=$true)][string]$TargetDatabase,
    [string]$PrivateConfig,
    [string]$PostgresBin,
    [string]$Executable,
    [string]$ConfirmPlanSha256,
    [string]$ReceiptFile
)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
if(!$PrivateConfig){$PrivateConfig=Join-Path $taskRoot '.local/postgres-private.json'}
if(!$Executable){$Executable=Join-Path $taskRoot 'process-intelligence-rs.exe'}
$Executable=[IO.Path]::GetFullPath($Executable)
if($Database -cnotmatch '^[a-z][a-z0-9_]{0,62}$' -or $TargetDatabase -cnotmatch '^pi_restore_[a-z0-9_]{1,50}$' -or $Database -ceq $TargetDatabase){throw 'Use an existing source and a distinct NEW pi_restore_* verification database.'}
if($Mode -eq 'Apply' -and $ConfirmPlanSha256 -cnotmatch '^[a-fA-F0-9]{64}$'){throw 'Apply requires the exact SHA256 of the private verified plan.'}
if($Mode -eq 'Preview' -and $ConfirmPlanSha256){throw 'Confirmation is only accepted for Apply.'}
$taskPrivateRoot=[IO.Path]::GetFullPath((Join-Path $taskRoot '.local'))+[IO.Path]::DirectorySeparatorChar
$taskArchive=[IO.Path]::GetFullPath($BackupFile)
$taskPlan=[IO.Path]::GetFullPath($PlanFile)
$taskReceipt=if($ReceiptFile){[IO.Path]::GetFullPath($ReceiptFile)}else{$taskPlan+'.receipt.json'}
foreach($taskPath in @($taskArchive,$taskPlan,$taskReceipt)){
    if(!$taskPath.StartsWith($taskPrivateRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Archives, plans and receipts must stay inside this installation .local directory.'}
}
if(!(Test-Path -LiteralPath $taskArchive -PathType Leaf) -or !(Test-Path -LiteralPath ($taskArchive+'.manifest.json') -PathType Leaf)){throw 'Provide an existing full database archive and its original manifest.'}
foreach($taskExisting in @($taskArchive,($taskArchive+'.manifest.json'),$taskPlan,$taskReceipt)){
    if((Test-Path -LiteralPath $taskExisting) -and ((Get-Item -LiteralPath $taskExisting).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Private artifacts must not be reparse points.'}
}
if(!(Test-Path -LiteralPath $Executable -PathType Leaf)){throw 'Compatible executable not found.'}
if($Mode -eq 'Preview' -and (Test-Path -LiteralPath $taskPlan)){throw 'Plan already exists; choose a new private filename.'}
if($Mode -eq 'Apply' -and !(Test-Path -LiteralPath $taskPlan -PathType Leaf)){throw 'Verified plan not found.'}
if(Test-Path -LiteralPath $taskReceipt){throw 'Receipt already exists; choose a new filename without replacing evidence.'}

# Access-section-only ACL, no administrator requirement. Protect before loading
# credentials or creating artifacts. Reject junction/reparse traversal.
foreach($taskParent in @((Split-Path -Parent $taskArchive),(Split-Path -Parent $taskPlan),(Split-Path -Parent $taskReceipt))|Select-Object -Unique){
    $taskWalk=[IO.DirectoryInfo]::new($taskParent)
    while($taskWalk -and $taskWalk.FullName.StartsWith($taskPrivateRoot.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){
        if($taskWalk.Exists -and ($taskWalk.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Private artifact path contains a reparse point.'}
        $taskWalk=$taskWalk.Parent
    }
    New-Item -ItemType Directory -Path $taskParent -Force|Out-Null
    $taskRules=New-Object Security.AccessControl.DirectorySecurity
    $taskRules.SetAccessRuleProtection($true,$false)
    $taskRules.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().Name,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    $taskDirectory=[IO.DirectoryInfo]::new($taskParent)
    if($taskDirectory.PSObject.Methods['SetAccessControl']){$taskDirectory.SetAccessControl($taskRules)}else{[IO.FileSystemAclExtensions]::SetAccessControl($taskDirectory,$taskRules)}
    $taskAcl=Get-Acl -LiteralPath $taskParent
    $taskAclRules=@($taskAcl.Access)
    $taskSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if(!$taskAcl.AreAccessRulesProtected -or $taskAclRules.Count -ne 1 -or $taskAclRules[0].IsInherited -or $taskAclRules[0].AccessControlType -ne 'Allow' -or $taskAclRules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ne $taskSid -or [int]$taskAclRules[0].FileSystemRights -ne [int][Security.AccessControl.FileSystemRights]::FullControl){throw 'Private directory ACL verification failed.'}
}
if($Mode -eq 'Preview'){
    Write-Output 'Preview restores the supplied archive into a NEW verification database. No source rows are deleted. Failed targets are retained for inspection.'
    $taskRestore=@{Mode='Restore';BackupFile=$taskArchive;Database=$Database;TargetDatabase=$TargetDatabase;PrivateConfig=$PrivateConfig}
    if($PostgresBin){$taskRestore.PostgresBin=$PostgresBin}
    & (Join-Path $PSScriptRoot 'database-backup.ps1') @taskRestore
    if($LASTEXITCODE -ne 0){throw 'Verification restore failed. Source is unchanged; the isolated target is retained.'}
}
$taskConfig=Get-Content -LiteralPath $PrivateConfig -Raw|ConvertFrom-Json
if([int]$taskConfig.port -lt 1 -or [int]$taskConfig.port -gt 65535 -or !$taskConfig.admin_password){throw 'Private operator configuration is incomplete.'}
$taskPassword=([string]$taskConfig.admin_password).Replace('\','\\').Replace("'","\'")
$taskNames=@('PI_DATABASE_URL','PI_CLEANUP_RESTORE_URL','PI_CLEANUP_ARCHIVE','PI_CLEANUP_PLAN','PI_CLEANUP_CONFIRM_SHA','PI_CLEANUP_RECEIPT')
$taskPrevious=@{}
foreach($taskName in $taskNames){$taskPrevious[$taskName]=[Environment]::GetEnvironmentVariable($taskName,'Process')}
try{
    $env:PI_DATABASE_URL="host=127.0.0.1 port=$($taskConfig.port) user=pi_admin password='$taskPassword' dbname=$Database sslmode=disable"
    $env:PI_CLEANUP_RESTORE_URL="host=127.0.0.1 port=$($taskConfig.port) user=pi_admin password='$taskPassword' dbname=$TargetDatabase sslmode=disable"
    $env:PI_CLEANUP_ARCHIVE=$taskArchive
    $env:PI_CLEANUP_PLAN=$taskPlan
    $env:PI_CLEANUP_CONFIRM_SHA=$ConfirmPlanSha256
    $env:PI_CLEANUP_RECEIPT=$taskReceipt
    $taskArgument=if($Mode -eq 'Preview'){'--cleanup-storage-verify'}else{'--cleanup-storage-apply'}
    Push-Location -LiteralPath $taskRoot
    try{& $Executable $taskArgument;$taskExit=$LASTEXITCODE}finally{Pop-Location}
}finally{
    foreach($taskName in $taskNames){[Environment]::SetEnvironmentVariable($taskName,$taskPrevious[$taskName],'Process')}
    $taskConfig=$null;$taskPassword=$null
}
exit $taskExit
