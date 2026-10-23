param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$SourceSha,
    [Parameter(Mandatory)][string]$Fixture
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$windows=[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$comparison=if($windows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
$workspace=[IO.Path]::GetFullPath([string]$PWD)
$fixtureRoot=[IO.Path]::GetFullPath($Fixture)
$allowed=[IO.Path]::GetFullPath((Join-Path $workspace '.local/sprint21/root/sprint24'))+[IO.Path]::DirectorySeparatorChar
$sourcePath=[IO.Path]::GetFullPath($Source)
if(-not $fixtureRoot.StartsWith($allowed,$comparison) -or
   -not $sourcePath.StartsWith($workspace+[IO.Path]::DirectorySeparatorChar,$comparison) -or
   $SourceSha -cnotmatch '^[A-F0-9]{64}$' -or (Get-FileHash -LiteralPath $sourcePath).Hash -cne $SourceSha -or
   -not [IO.Directory]::Exists($fixtureRoot) -or @(Get-ChildItem -LiteralPath $fixtureRoot -Force).Count -ne 0){throw 'fresh_owned_fixture_and_exact_source'}
$rows=[Collections.Generic.List[object]]::new()
$links=[Collections.Generic.List[object]]::new()
function Need([bool]$Condition,[string]$Reason){if(-not $Condition){throw $Reason}}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash}
function Access([string]$Path){
    if(-not $windows){return 'WINDOWS_ACL_NOT_MEASURED_ON_THIS_OS'}
    ([IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($Path))).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
}
function DirectoryAclState([string]$Path){
    if(-not $windows){return 'WINDOWS_ACL_NOT_MEASURED_ON_THIS_OS'}
    try{$attributes=[IO.File]::GetAttributes($Path)}catch{
        $cause=$_.Exception;if($cause.InnerException){$cause=$cause.InnerException}
        if($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]){return 'ABSENT'}
        throw
    }
    if(-not ($attributes -band [IO.FileAttributes]::Directory)){return 'NOT_DIRECTORY'}
    if($attributes -band [IO.FileAttributes]::ReparsePoint){
        $target=[IO.DirectoryInfo]::new($Path).ResolveLinkTarget($false)
        if($null -eq $target -or -not $target.Exists){return 'BROKEN_LINK_ACL_NOT_MEASURED'}
    }
    Access $Path
}
function Save([string]$Path,[object]$Value){
    $raw=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 12))
    Need ($raw.Length -le 65536) 'proof_bound'
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($raw,0,$raw.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function New-Link([string]$Path,[string]$Target){
    $kind=if($windows){'Junction'}else{'SymbolicLink'}
    New-Item -ItemType $kind -Path $Path -Target $Target -ErrorAction Stop|Out-Null
    $entry=@{path=[IO.Path]::GetFullPath($Path);target=[IO.Path]::GetFullPath($Target);removed=$false}
    $links.Add($entry)
    Need (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'actual_reparse_fixture'
}
function Remove-ExactLinks {
    foreach($entry in $links){
        if($entry.removed){continue}
        Need ($entry.path.StartsWith($fixtureRoot+[IO.Path]::DirectorySeparatorChar,$comparison) -and
              $entry.target.StartsWith($fixtureRoot+[IO.Path]::DirectorySeparatorChar,$comparison)) 'link_cleanup_fixture_scope'
        $item=Get-Item -LiteralPath $entry.path -Force -ErrorAction Stop
        Need (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'link_cleanup_type'
        $actual=$item.ResolveLinkTarget($false)
        Need ($null -ne $actual -and $actual.FullName.Equals($entry.target,$comparison)) 'link_cleanup_exact_target'
        [IO.Directory]::Delete($entry.path,$false)
        $entry.removed=$true
    }
}
$unsafe='Unsafe archive path: links and reparse points inside installation .local are not allowed.'
$collision='Backup archive or manifest already exists; choose a new filename.'
$regular='Archive and manifest targets must be regular files.'
$caseAlias=@{id='case-variant';kind='case-variant';error='Store private database archives inside this installation .local directory.'}
if($windows){$caseAlias.positive=$true}
$cases=@(
    @{id='root-link';kind='root-link';error=$unsafe},
    @{id='parent-link';kind='parent-link';error=$unsafe},
    @{id='restore-parent-link';kind='parent-link';mode='Restore';error=$unsafe},
    @{id='archive-link';kind='archive-link';error=$unsafe},
    @{id='manifest-link';kind='manifest-link';error=$unsafe},
    @{id='broken-parent-link';kind='broken-parent-link';error=$unsafe},
    @{id='archive-collision';kind='archive-collision';error=$collision},
    @{id='manifest-collision';kind='manifest-collision';error=$collision},
    @{id='parent-file';kind='parent-file';error='Archive parent must be a directory.'},
    @{id='directory-leaf';kind='directory-leaf';error=$regular},
    @{id='restore-missing';kind='ordinary';mode='Restore';error='Restore requires an existing regular archive and manifest.'},
    @{id='prefix-escape';kind='prefix-escape';error='Store private database archives inside this installation .local directory.'},
    $caseAlias,
    @{id='ordinary-existing';kind='ordinary-existing';positive=$true},
    @{id='ordinary-new';kind='ordinary-new';positive=$true}
)
try {
 foreach($case in $cases){
    if($case.ContainsKey('positive') -and -not $windows){
        $rows.Add(@{id=$case.id;status='SKIP_WINDOWS_ACL_POSITIVE_ON_NONWINDOWS';not_a_backup_pass=$true});continue
    }
    $base=Join-Path $fixtureRoot $case.id
    $installation=Join-Path $base 'installation'
    $tools=Join-Path $installation 'tools'
    $local=Join-Path $installation '.local'
    $external=Join-Path $base 'external'
    $externalChild=Join-Path $external 'existing-backup-directory'
    [IO.Directory]::CreateDirectory($tools)|Out-Null
    [IO.Directory]::CreateDirectory($externalChild)|Out-Null
    [IO.File]::Copy($sourcePath,(Join-Path $tools 'database-backup.ps1'),$false)
    $sentinel=Join-Path $externalChild 'sentinel.txt'
    [IO.File]::WriteAllText($sentinel,'Synthetic boundary sentinel; no private data.',[Text.UTF8Encoding]::new($false))
    if($windows){
        $acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($externalChild))
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($externalChild),$acl)
    }
    if($case.kind -eq 'root-link'){New-Link $local $external}else{[IO.Directory]::CreateDirectory($local)|Out-Null}
    $archive=Join-Path $local 'probe.dump'
    switch($case.kind){
        'parent-link' {New-Link (Join-Path $local 'link') $external;$archive=Join-Path $local 'link/existing-backup-directory/probe.dump'}
        'archive-link' {New-Link $archive $external}
        'manifest-link' {New-Link ($archive+'.manifest.json') $external}
        'broken-parent-link' {
            $broken=Join-Path $external 'removed-empty-target'
            [IO.Directory]::CreateDirectory($broken)|Out-Null
            New-Link (Join-Path $local 'link') $broken
            [IO.Directory]::Delete($broken,$false)
            $archive=Join-Path $local 'link/probe.dump'
        }
        'archive-collision' {[IO.File]::WriteAllText($archive,'Existing synthetic archive must not change.')}
        'manifest-collision' {[IO.File]::WriteAllText(($archive+'.manifest.json'),'Existing synthetic manifest must not change.')}
        'parent-file' {[IO.File]::WriteAllText((Join-Path $local 'not-directory'),'ordinary file');$archive=Join-Path $local 'not-directory/probe.dump'}
        'directory-leaf' {[IO.Directory]::CreateDirectory($archive)|Out-Null}
        'prefix-escape' {$archive=Join-Path $installation '.local-other/new/probe.dump'}
        'case-variant' {$archive=Join-Path $installation '.LOCAL/new/probe.dump'}
        'ordinary-existing' {$parent=Join-Path $local 'existing';[IO.Directory]::CreateDirectory($parent)|Out-Null;$archive=Join-Path $parent 'probe.dump'}
        'ordinary-new' {$archive=Join-Path $local 'new/nested/probe.dump'}
    }
    $parent=Split-Path -Parent $archive
    $parentExisted=[IO.Directory]::Exists($parent)
    $before=@{external_acl=(Access $externalChild);external_root_acl=(Access $external);local_acl=(DirectoryAclState $local);parent_acl=(DirectoryAclState $parent);sentinel=(Hash $sentinel);entries=@(Get-ChildItem -LiteralPath $externalChild -Force|ForEach-Object Name)}
    $collisionPath=if($case.kind -eq 'archive-collision'){$archive}elseif($case.kind -eq 'manifest-collision'){$archive+'.manifest.json'}else{$null}
    $collisionBefore=if($null -ne $collisionPath){Hash $collisionPath}else{$null}
    $parameters=@{Mode=if($case.ContainsKey('mode')){$case.mode}else{'Backup'};BackupFile=$archive;PrivateConfig=(Join-Path $installation 'nonexistent-private-config.json');PostgresBin=(Join-Path $installation 'nonexistent-bin')}
    if($parameters.Mode -eq 'Restore'){$parameters.TargetDatabase='pi_restore_fixture'}
    $caught=$null
    try{& (Join-Path $tools 'database-backup.ps1') @parameters|Out-Null}catch{$caught=$_}
    Need ($null -ne $caught) ('expected_refusal_'+$case.id)
    $positive=$case.ContainsKey('positive')
    if($positive){
        Need ($caught.FullyQualifiedErrorId -match '^PathNotFound,Microsoft.PowerShell.Commands.GetContentCommand') ('ordinary_path_not_admitted_'+$case.id)
        $acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($parent))
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        Need ($acl.AreAccessRulesProtected -and $rules.Count -eq 1 -and $rules[0].IdentityReference.Value -ceq $sid -and
              $rules[0].AccessControlType -eq 'Allow' -and ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) ('ordinary_private_acl_'+$case.id)
        Need (-not (Test-Path -LiteralPath $archive)) 'ordinary_no_archive_without_config'
    }else{
        Need ($caught.Exception.Message -ceq $case.error) ('wrong_refusal_'+$case.id+': '+$caught.Exception.Message)
        Need ($parentExisted -or -not [IO.Directory]::Exists($parent)) ('refused_path_created_parent_'+$case.id)
    }
    $after=@{external_acl=(Access $externalChild);external_root_acl=(Access $external);local_acl=(DirectoryAclState $local);parent_acl=(DirectoryAclState $parent);sentinel=(Hash $sentinel);entries=@(Get-ChildItem -LiteralPath $externalChild -Force|ForEach-Object Name)}
    Need ($before.external_acl -ceq $after.external_acl -and $before.external_root_acl -ceq $after.external_root_acl -and $before.sentinel -ceq $after.sentinel -and ($before.entries -join ',' ) -ceq ($after.entries -join ',')) ('outside_changed_'+$case.id)
    if(-not $positive){Need ($before.local_acl -ceq $after.local_acl -and $before.parent_acl -ceq $after.parent_acl) ('refused_local_acl_changed_'+$case.id)}
    if($null -ne $collisionPath){Need ((Hash $collisionPath) -ceq $collisionBefore) ('collision_overwrite_'+$case.id)}
    $parentExistsAfter=[IO.Directory]::Exists($parent)
    Remove-ExactLinks
    $row=@{id=$case.id;status='PASS';expected_error_id=$caught.FullyQualifiedErrorId;outside_unchanged=$true;collision_unchanged=($null -ne $collisionPath);ordinary_path_admitted_only_to_missing_config=$positive;postgres_started=$false;observed_before=$before;observed_after=$after;parent_existed_before=$parentExisted;parent_exists_after=$parentExistsAfter;collision_sha256_before=$collisionBefore;collision_sha256_after=if($null -ne $collisionPath){Hash $collisionPath}else{$null}}
    $rows.Add($row)
    Save (Join-Path $fixtureRoot ($case.id+'.json')) $row
 }
}finally{Remove-ExactLinks}
Need (@($links|Where-Object {-not $_.removed}).Count -eq 0) 'all_links_removed'
$proof=@{status=if($windows){'WINDOWS_PATH_AND_LOCAL_ACL_CONTROLS_PASS'}else{'PORTABLE_NEGATIVE_CONTROLS_PASS_WINDOWS_POSITIVES_SKIPPED'};source_sha256=$SourceSha;checks=@($rows.ToArray());passed=@($rows|Where-Object {$_.status -eq 'PASS'}).Count;skipped=@($rows|Where-Object {$_.status -ne 'PASS'}).Count;all_links_removed_nonrecursive=$true;postgres_or_real_config=$false;limits='Existing links and path collisions only; no atomic concurrent replacement guarantee or full database backup/restore execution.'}
Save (Join-Path $fixtureRoot 'proof.json') $proof
$proof|Select-Object status,source_sha256,passed,skipped,all_links_removed_nonrecursive,postgres_or_real_config,limits|ConvertTo-Json
