param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$Output)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../sprint21/owned-runtime.psm1') -Force -DisableNameChecking
$workspacePath=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if([string]$PWD -cne $workspacePath){throw 'workspace_exact'}
$expected=Join-Path $workspacePath '.local/sprint21/root/sprint22/counterfactual-archive01'
if([IO.Path]::GetFullPath($Output) -cne $expected){throw 'archive_output_exact'}
$out=New-OwnedPrivateDirectory $Output
$clock=[Diagnostics.Stopwatch]::StartNew();$all=[Collections.Generic.List[object]]::new();[long]$archives=0;$script:nextFreeCheck=0
$resolvedWorkspace=[PiResolvedPath]::Get($workspacePath).TrimEnd('\')
function Bound {if($clock.Elapsed.TotalSeconds -gt 600 -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]'2026-10-23T05:05:00Z'){throw 'archive_time_bound'};if($clock.ElapsedMilliseconds -ge $script:nextFreeCheck){if((Get-PSDrive C).Free -lt 8GB){throw 'archive_free_floor'};$script:nextFreeCheck=$clock.ElapsedMilliseconds+1000}}
function Quiet {
 $processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -and $_.ExecutablePath.StartsWith($workspacePath+'\',[StringComparison]::OrdinalIgnoreCase)})
 if($processes.Count){throw 'workspace_native_workload_not_quiet'}
}
function Safe([string]$Path,[string]$Base){
 $p=[IO.Path]::GetFullPath($Path);if(!$p.StartsWith($Base+'\',[StringComparison]::OrdinalIgnoreCase) -and $p -cne $Base){throw 'archive_path_boundary'}
 $current=$p
 while($true){$attrs=[IO.File]::GetAttributes($current);if($attrs -band [IO.FileAttributes]::ReparsePoint){throw 'archive_reparse_refused'};if($current.Equals($workspacePath,[StringComparison]::OrdinalIgnoreCase)){break};$current=[IO.Path]::GetDirectoryName($current);if(!$current){throw 'archive_workspace_ancestor_missing'}}
 $relative=[IO.Path]::GetRelativePath($workspacePath,$p)
 $expectedResolved=$resolvedWorkspace+'\'+$relative
 if(![PiResolvedPath]::Get($p).Equals($expectedResolved,[StringComparison]::OrdinalIgnoreCase)){throw 'archive_resolved_path_mismatch'}
}
function Snapshot([string]$Base){
 $queue=[Collections.Generic.Queue[IO.DirectoryInfo]]::new();$queue.Enqueue([IO.DirectoryInfo]::new($Base));$nodes=[Collections.Generic.List[IO.FileSystemInfo]]::new()
 while($queue.Count){Bound;$directory=$queue.Dequeue();Safe $directory.FullName $Base
  foreach($node in $directory.EnumerateFileSystemInfos()){
   Bound;if($nodes.Count -ge 9000){throw 'archive_entry_bound'};Safe $node.FullName $Base
   $nodes.Add($node);if($node.Attributes -band [IO.FileAttributes]::Directory){$queue.Enqueue([IO.DirectoryInfo]$node)}
  }
 };return $nodes.ToArray()
}
Quiet
foreach($name in @('public-source01','conversion-audit01','conversion-audit02','public-projection02')){
 Bound
 $base=[IO.Path]::GetFullPath((Join-Path $workspacePath ('.local/sprint21/root/'+$name+'/counterfactuals')))
 if($base -cne (Join-Path $workspacePath ('.local/sprint21/root/'+$name+'/counterfactuals'))){throw 'archive_source_exact'}
 Safe $base $base
 if(Test-Path -LiteralPath (Join-Path $base 'postmaster.pid')){throw 'historical_cluster_pidfile_refused'}
 $nodes=@(Snapshot $base)
 $manifest=[Collections.Generic.List[object]]::new()
 $zipPath=Join-Path $out ($name+'.zip');$stream=[IO.File]::Open($zipPath,'CreateNew','ReadWrite','Read')
 try{
  $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
  try{foreach($node in $nodes){
   Bound;Safe $node.FullName $base
   $relative=[IO.Path]::GetRelativePath($base,$node.FullName).Replace('\','/')
   $directory=($node.Attributes -band [IO.FileAttributes]::Directory) -ne 0
   $m=@{path=$relative;directory=$directory;attributes=[int]$node.Attributes;creation_utc=$node.CreationTimeUtc.ToString('o');last_write_utc=$node.LastWriteTimeUtc.ToString('o');last_access_utc=$node.LastAccessTimeUtc.ToString('o')}
   if($directory){[void]$zip.CreateEntry($relative+'/')}else{
    if($node.Length -gt 64KB){throw 'archive_file_bound'}
    $input=[IO.File]::Open($node.FullName,'Open','Read','Read')
    try{$m.bytes=$input.Length;$m.sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($input));$input.Position=0;$entry=$zip.CreateEntry($relative,[IO.Compression.CompressionLevel]::Fastest);$dest=$entry.Open();try{$input.CopyTo($dest,65536)}finally{$dest.Dispose()}}finally{$input.Dispose()}
   }
   $manifest.Add($m)
   if($archives+$stream.Length -gt 64MB){throw 'aggregate_archive_size_bound_no_source_removal'}
  }}finally{$zip.Dispose()}
  $stream.Flush($true)
 }finally{$stream.Dispose()}
 $archives+=(Get-Item -LiteralPath $zipPath).Length;if($archives -gt 64MB){throw 'aggregate_archive_size_bound_no_source_removal'}
 $read=[IO.Compression.ZipFile]::OpenRead($zipPath)
 try{
  if($read.Entries.Count -ne $manifest.Count){throw 'archive_member_count'}
  $map=@{};foreach($entry in $read.Entries){if($map.ContainsKey($entry.FullName)){throw 'archive_duplicate_member'};$map[$entry.FullName]=$entry}
  foreach($m in $manifest){Bound;$key=$m.path+$(if($m.directory){'/'}else{''});if(!$map.ContainsKey($key)){throw 'archive_member_set'};if(!$m.directory){$e=$map[$key];if($e.Length -ne $m.bytes){throw 'archive_length'};$s=$e.Open();try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s))}finally{$s.Dispose()};if($hash -cne $m.sha256){throw 'archive_byte_hash'}}}
 }finally{$read.Dispose()}
 $baseNode=Get-Item -LiteralPath $base
 $bundle=@{source=$base;archive=$zipPath;archive_sha256=(Get-FileHash $zipPath).Hash;entries=$manifest.ToArray();source_root=@{attributes=[int]$baseNode.Attributes;creation_utc=$baseNode.CreationTimeUtc.ToString('o');last_write_utc=$baseNode.LastWriteTimeUtc.ToString('o');last_access_utc=$baseNode.LastAccessTimeUtc.ToString('o')};verified_before_any_removal=$true}
 Write-OwnedJson (Join-Path $out ($name+'-manifest.json')) $bundle
 $all.Add($bundle)
}
# Every ZIP is closed, reopened, and verified before removing any original.
Write-OwnedJson (Join-Path $out 'all-archives-verified-before-removal.json') @{utc=[DateTimeOffset]::UtcNow.ToString('o');archives=$all.Count;archive_bytes=$archives;source_bytes_preserved=$true;removal_started=$false}
foreach($bundle in $all){
 Bound;Quiet;$base=$bundle.source;Safe $base $base
 if(Test-Path -LiteralPath (Join-Path $base 'postmaster.pid')){throw 'pidfile_appeared_no_more_removal'}
 $now=@(Snapshot $base);if($now.Count -ne $bundle.entries.Count){throw 'source_member_set_changed'}
 foreach($m in $bundle.entries){Bound;$path=Join-Path $base $m.path;Safe $path $base;$node=Get-Item -LiteralPath $path;if([int]$node.Attributes -ne $m.attributes -or $node.CreationTimeUtc.ToString('o') -cne $m.creation_utc -or $node.LastWriteTimeUtc.ToString('o') -cne $m.last_write_utc){throw 'source_metadata_changed'};if(!$m.directory -and ($node.Length -ne $m.bytes -or (Get-FileHash -LiteralPath $path).Hash -cne $m.sha256)){throw 'source_bytes_changed'}}
 foreach($m in $bundle.entries|Where-Object{!$_.directory}){Bound;$path=[IO.Path]::GetFullPath((Join-Path $base $m.path));Safe $path $base;Remove-Item -LiteralPath $path -ErrorAction Stop}
 foreach($m in $bundle.entries|Where-Object directory|Sort-Object{$_.path.Length} -Descending){Bound;$path=[IO.Path]::GetFullPath((Join-Path $base $m.path));Safe $path $base;[IO.Directory]::Delete($path,$false)}
 Bound;[IO.Directory]::Delete($base,$false)
 Write-OwnedJson (Join-Path $out ((Split-Path (Split-Path $base -Parent) -Leaf)+'-compacted.json')) @{utc=[DateTimeOffset]::UtcNow.ToString('o');source=$base;archive_sha256=$bundle.archive_sha256;original_absent=!(Test-Path -LiteralPath $base);all_file_bytes_preserved=$true}
}
Bound;Write-OwnedJson (Join-Path $out 'archive-result.json') @{status='BYTE_VERIFIED_FOUR_COUNTERFACTUAL_TREES_COMPACTED';utc=[DateTimeOffset]::UtcNow.ToString('o');trees=$all.Count;archive_bytes=$archives;elapsed_ms=$clock.ElapsedMilliseconds;scope='Only four exact old counterfactual subtrees; every negative-test byte preserved in verified private archives. All PG directories, binary/input fixtures, canonical public ZIPs, and evidence receipts outside those subtrees unchanged. File times/attributes recorded; no ACL/NTFS fidelity or restoration exercise claim.'}
