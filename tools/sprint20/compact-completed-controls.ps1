param([Parameter(Mandatory)][string]$Workspace)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspaceBoundary=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if($workspaceBoundary -cne [IO.Path]::GetFullPath([string]$PWD).TrimEnd('\')){throw 'exact_current_workspace_required'}
$root=[IO.Path]::GetFullPath((Join-Path $workspaceBoundary '.local/sprint20/root'))
function Assert-RegularAncestors([string]$Path){
 $current=[IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
 while($current){
  if($current.Exists -and ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'ancestor_reparse_refused'}
  if($current.FullName.Equals($workspaceBoundary,[StringComparison]::OrdinalIgnoreCase)){return}
  $current=$current.Parent
 }
 throw 'ancestor_outside_current_workspace'
}
Assert-RegularAncestors $root
$destination=Join-Path $root 'completed-controls-archives01'
if(Test-Path -LiteralPath $destination){throw 'fresh_archive_directory_required'}
[void][IO.Directory]::CreateDirectory($destination)
$names=@('conversion-counterfactuals02','conversion-counterfactuals03','conversion-public-counterfactuals01','miner-counterfactuals01','miner-counterfactuals02','miner-public-counterfactuals01')
foreach($name in $names){
 $parent=[IO.Path]::GetFullPath((Join-Path $root $name))
 Assert-RegularAncestors $parent
 if(!$parent.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'owned_parent_boundary'}
 $result=Get-Content -LiteralPath (Join-Path $parent 'result.json') -Raw|ConvertFrom-Json
 $resultSha=(Get-FileHash -LiteralPath (Join-Path $parent 'result.json')).Hash
 if($result.status -cnotin @('ACTUAL_DATA_COUNTERFACTUALS_PASS','PASS_ALL_SEVEN_SCIENCE_SPECIFIC_NEGATIVE_CONTROLS','PASS_FOUR_PROJECTED_PROVENANCE_NEGATIVE_CONTROLS')){throw 'completed_positive_controls_required'}
 $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($control in $result.controls){
  if($control.control -cnotmatch '^[a-z][a-z0-9_]+$'){throw 'exact_control_name'}
  [void]$allowed.Add($control.control)
  if($name.StartsWith('miner-')){[void]$allowed.Add($control.control+'-semantics')}
 }
 $directories=@(Get-ChildItem -LiteralPath $parent -Directory|Where-Object{$_.Name -cne 'baseline-semantics'})
 if(!$allowed.SetEquals([string[]]@($directories|ForEach-Object{$_.Name}))){throw 'unknown_or_missing_control_directory'}
 $rows=[Collections.Generic.List[object]]::new();[long]$total=0
 $started=[DateTimeOffset]::UtcNow; $visited=0
 foreach($dir in $directories){
  $pending=[Collections.Generic.Queue[IO.FileSystemInfo]]::new();$pending.Enqueue($dir)
  while($pending.Count){
   $entry=$pending.Dequeue();$visited++
   if($visited -gt 25000 -or ([DateTimeOffset]::UtcNow-$started).TotalSeconds -gt 180){throw 'archive_enumeration_bound'}
   if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse_refused'}
   if($entry -is [IO.DirectoryInfo]){foreach($child in $entry.GetFileSystemInfos()){$pending.Enqueue($child)}}else{
    $total+=$entry.Length
    if($rows.Count -ge 20000 -or $total -gt 512MB -or $entry.Length -gt 64MB){throw 'archive_input_cap'}
    $rows.Add(@{path=[IO.Path]::GetRelativePath($parent,$entry.FullName).Replace('\','/');bytes=$entry.Length;sha256=(Get-FileHash -LiteralPath $entry.FullName).Hash})
   }
  }
 }
 $archive=Join-Path $destination ($name+'.zip')
 $zip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
 try{foreach($row in $rows){[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $parent $row.path),$row.path,[IO.Compression.CompressionLevel]::Fastest)}}finally{$zip.Dispose()}
 if((Get-Item -LiteralPath $archive).Length -gt 128MB){throw 'archive_output_cap'}
 $zip=[IO.Compression.ZipFile]::OpenRead($archive)
 try{
  if($zip.Entries.Count -ne $rows.Count){throw 'archive_member_count'}
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($row in $rows){
   if(!$seen.Add($row.path)){throw 'duplicate_source_path'}
   $entry=$zip.GetEntry($row.path)
   if(!$entry -or $entry.Length -ne $row.bytes){throw 'archive_member_size'}
   $stream=$entry.Open();try{$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}
   if($sha -cne $row.sha256 -or (Get-FileHash -LiteralPath (Join-Path $parent $row.path)).Hash -cne $row.sha256){throw 'archive_or_original_hash'}
  }
 }finally{$zip.Dispose()}
 $afterNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($dir in $directories){foreach($file in [IO.Directory]::EnumerateFiles($dir.FullName,'*',[IO.SearchOption]::AllDirectories)){
  if($afterNames.Count -ge 20000){throw 'archive_post_inventory_bound'}
  [void]$afterNames.Add([IO.Path]::GetRelativePath($parent,$file).Replace('\','/'))
 }}
 if(!$afterNames.SetEquals([string[]]@($rows|ForEach-Object{$_.path}))){throw 'source_inventory_changed'}
 $receipt=@{status='ALL_SYNTHETIC_CLONE_MEMBERS_AND_ORIGINAL_BYTES_VERIFIED_BEFORE_COMPACTION';parent=$name;files=$rows.Count;bytes=$total;archive_sha256=(Get-FileHash -LiteralPath $archive).Hash;original_result_sha256=$resultSha;files_inventory=$rows.ToArray();scientific_baselines_removed=$false}
 [IO.File]::WriteAllText((Join-Path $destination ($name+'.json')),($receipt|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
 foreach($dir in $directories){
  $exact=[IO.Path]::GetFullPath($dir.FullName)
  Assert-RegularAncestors $exact
  if(!$exact.StartsWith($parent+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $exact -ceq $parent -or $dir.Name -ceq 'baseline-semantics'){throw 'exact_verified_clone_remove_boundary'}
  if((Get-FileHash -LiteralPath (Join-Path $parent 'result.json')).Hash -cne $resultSha -or (Get-Item -LiteralPath $exact).CreationTimeUtc -ne $dir.CreationTimeUtc){throw 'source_identity_changed'}
  $prefix=$dir.Name+'/'
  $expected=@($rows|Where-Object{$_.path.StartsWith($prefix,[StringComparison]::Ordinal)})
  $actual=@([IO.Directory]::EnumerateFiles($exact,'*',[IO.SearchOption]::AllDirectories))
  if($actual.Count -ne $expected.Count){throw 'source_final_file_count'}
  foreach($row in $expected){if((Get-FileHash -LiteralPath (Join-Path $parent $row.path)).Hash -cne $row.sha256){throw 'source_final_hash'}}
  Remove-Item -LiteralPath $exact -Recurse -Force
 }
 [IO.File]::WriteAllText((Join-Path $destination ($name+'.completed.json')),(@{status='VERIFIED_SYNTHETIC_CLONES_COMPACTED_REVERSIBLY';archive_sha256=$receipt.archive_sha256;files=$rows.Count;utc=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 Write-Output ($name+': '+$rows.Count+' verified files archived')
}
