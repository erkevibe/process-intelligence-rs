param([Parameter(Mandatory)][string]$Output)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PWD 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
$ws=[IO.Path]::GetFullPath($PWD.Path);$root=Join-Path $ws '.local/sprint21/root';$qaBase=Join-Path $ws '.local/sprint21/qa';$base=Join-Path $qaBase 'capacity-public-source01'
$source=Join-Path $base 'source';$downloaded=Join-Path $source 'process-intelligence-rs-08371fea317014005ea876667cd095e8608d60f9';$controls=Join-Path $base 'counterfactuals';$zip=Join-Path $Output 'qa-closed-counterfactuals.zip'
if($Output -cne (Join-Path $root 'complexity-qa-compaction02')){throw 'exact_output'}
Assert-OwnedPrivateDirectory $Output
# Root output remains Root-bounded. Separate exact QA-source ACL assertion;
# no change to either existing owned runtime or its directory boundaries.
if([IO.Path]::GetFullPath($base) -cne (Join-Path $ws '.local/sprint21/qa/capacity-public-source01')){throw 'exact_qa_source_base'}
Assert-OwnedNoReparse $base
$qaAcl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($base))
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
if($qaAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or !$qaAcl.AreAccessRulesProtected){throw 'qa_private_owner'}
$qaRules=@($qaAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if($qaRules.Count -ne 1 -or $qaRules[0].IdentityReference.Value -cne $sid.Value -or $qaRules[0].AccessControlType -ne 'Allow' -or ($qaRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'qa_private_rules'}
$deadline=[DateTimeOffset]'2026-10-22T23:05:00Z'
$script:freeCheckUtc=[DateTimeOffset]::MinValue;$script:boundCalls=0
function Bounds {$now=[DateTimeOffset]::UtcNow;if($now -ge $deadline){throw 'cleanup_time'};if((($script:boundCalls++ -band 127) -eq 0) -or $now -ge $script:freeCheckUtc){if((Get-PSDrive C).Free -lt 8GB){throw 'cleanup_free_floor'};$script:freeCheckUtc=$now.AddSeconds(1)}}
function FastHash([string]$Path){$stream=[IO.File]::OpenRead($Path);try{return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}}
function Chain([string]$Path){$p=[IO.Path]::GetFullPath($Path);if(!$p.StartsWith($ws+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'outside_workspace'};while($p -cne $ws){if(([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'reparse_refused'};$p=[IO.Path]::GetDirectoryName($p)};if(([IO.File]::GetAttributes($ws) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'workspace_reparse'}}
foreach($pidValue in @(23044,39988,41888)){if(Get-Process -Id $pidValue -ErrorAction SilentlyContinue){throw 'original_pid_present_or_reused'}}
$active=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{($_.ExecutablePath -and $_.ExecutablePath -ieq (Join-Path $root 'accepted-c01/process-intelligence-rs.exe')) -or ($_.ExecutablePath -and $_.ExecutablePath -ieq (Join-Path $ws '.local/postgres18/pgsql/bin/postgres.exe') -and $_.CommandLine -match 'pgdata11')});if($active.Count){throw 'product_not_quiet'}
Assert-OwnedHash (Join-Path $base 'public-source.zip') '41E69047A837F0910EC0D2A6F58AE5209E2FD0D50033CD4C7F1A8AA5EA2301F1'
Assert-OwnedHash (Join-Path $base 'readback.json') '33F5AB0835D03211FDF9B1024B96E9E66419A4ADDBBDC54408BA56D618D17C36'
$inventory=Get-Content (Join-Path $base 'readback.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$entriesBefore=@{};foreach($dir in @($source,$controls)){Chain $dir;$entriesBefore[$dir]=@([IO.Directory]::EnumerateFileSystemEntries($dir,'*',[IO.SearchOption]::AllDirectories));foreach($entry in $entriesBefore[$dir]){Chain $entry}}
$sourceFiles=@([IO.Directory]::EnumerateFiles($source,'*',[IO.SearchOption]::AllDirectories));if($sourceFiles.Count -ne 5172 -or $inventory.files -ne 5172){throw 'source_count'}
foreach($file in $sourceFiles){Bounds;$name=[IO.Path]::GetRelativePath($downloaded,$file).Replace('\','/');if(!$inventory.all_files.ContainsKey($name)){throw 'source_extra'};$expected=$inventory.all_files[$name];if((Get-Item -LiteralPath $file).Length -ne $expected.bytes -or (FastHash $file) -ine $expected.sha256){throw 'source_changed'}}
$files=@([IO.Directory]::EnumerateFiles($controls,'*',[IO.SearchOption]::AllDirectories));if($files.Count -ne 5029){throw 'counterfactual_count'}
$before=@{};foreach($file in $files){Bounds;$name=[IO.Path]::GetRelativePath($controls,$file).Replace('\','/');$before[$name]=@{bytes=(Get-Item -LiteralPath $file).Length;sha256=(FastHash $file)}}
if(Test-Path -LiteralPath $zip){throw 'archive_not_fresh'}
[IO.Compression.ZipFile]::CreateFromDirectory($controls,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
$archive=[IO.Compression.ZipFile]::OpenRead($zip);$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
try{foreach($entry in $archive.Entries){Bounds;if($entry.FullName.EndsWith('/')){continue};if(!$seen.Add($entry.FullName) -or !$before.ContainsKey($entry.FullName)){throw 'archive_entry_set'};$expected=$before[$entry.FullName];$stream=$entry.Open();try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()};if($entry.Length -ne $expected.bytes -or $hash -cne $expected.sha256){throw 'archive_member_changed'}};if($seen.Count -ne 5029){throw 'archive_count'}}finally{$archive.Dispose()}
# Recheck exact entries, containment, lengths and hashes for BOTH targets before removal.
foreach($target in @($source,$controls)){
 Bounds;Chain $target
 $actual=@([IO.Directory]::EnumerateFileSystemEntries($target,'*',[IO.SearchOption]::AllDirectories))
 $set=[Collections.Generic.HashSet[string]]::new([string[]]$entriesBefore[$target],[StringComparer]::OrdinalIgnoreCase)
 if(!$set.SetEquals([string[]]$actual)){throw 'target_entries_changed_before_removal'}
 foreach($entry in $actual){Chain $entry}
 foreach($file in [IO.Directory]::EnumerateFiles($target,'*',[IO.SearchOption]::AllDirectories)){
  Bounds
  if($target -ceq $source){$name=[IO.Path]::GetRelativePath($downloaded,$file).Replace('\','/');$expected=$inventory.all_files[$name]}else{$name=[IO.Path]::GetRelativePath($controls,$file).Replace('\','/');$expected=$before[$name]}
  if(!$expected -or (Get-Item -LiteralPath $file).Length -ne $expected.bytes -or (FastHash $file) -ine $expected.sha256){throw 'target_changed_before_removal'}
 }
}
Write-OwnedJson (Join-Path $Output 'before-removal-proof.json') @{source_files=5172;source_readback_sha256='33F5AB0835D03211FDF9B1024B96E9E66419A4ADDBBDC54408BA56D618D17C36';source_public_zip_sha256='41E69047A837F0910EC0D2A6F58AE5209E2FD0D50033CD4C7F1A8AA5EA2301F1';control_archive_sha256=Get-OwnedHash $zip;control_files=5029;control_members=$before;exact_targets=@($source,$controls);old_resource_timeout_cause_not_proven=$true}
foreach($target in @($source,$controls)){Bounds;Chain $target;if($target -cnotin @((Join-Path $qaBase 'capacity-public-source01/source'),(Join-Path $qaBase 'capacity-public-source01/counterfactuals'))){throw 'literal_target_mismatch'};Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop;if(Test-Path -LiteralPath $target){throw 'target_not_removed'}}
Assert-OwnedHash (Join-Path $base 'public-source.zip') '41E69047A837F0910EC0D2A6F58AE5209E2FD0D50033CD4C7F1A8AA5EA2301F1'
Write-OwnedJson (Join-Path $Output 'cleanup-proof.json') @{status='ONLY_TWO_VERIFIED_CLOSED_QA_READBACK_DIRECTORIES_REMOVED';removed_files=10201;unique_counterfactual_data_retained_in_verified_archive=$true;qa_original_receipts_untouched=$true;original_attempt_receipts_untouched=$true;root_failed_cleanup_history_preserved=$true;bounds_not_relaxed=$true;no_measurement_repeated=$true;archive_sha256=Get-OwnedHash $zip;utc=[DateTimeOffset]::UtcNow.ToString('o')}