# Read-only bounded sampling. Only vanished compiler target entries may be skipped.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Test-S18GoneTargetError([Exception]$Error,[string]$Path,[string]$Target) {
 $full=[IO.Path]::GetFullPath($Path)
 $prefix=[IO.Path]::GetFullPath($Target).TrimEnd('\')+[IO.Path]::DirectorySeparatorChar
 $cause=$Error.GetBaseException()
 if(!$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
  !($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException])){return $false}
 try{[void][IO.File]::GetAttributes($full);return $false}catch{
  $current=$_.Exception.GetBaseException()
  return $current -is [IO.FileNotFoundException] -or $current -is [IO.DirectoryNotFoundException]
 }
}
function Get-S18ResourceSnapshot([string]$Root,[string]$Target) {
 $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
 $compiler=[IO.Path]::GetFullPath($Target)
 if(!$compiler.Equals((Join-Path $base 'root/target'),[StringComparison]::OrdinalIgnoreCase)){throw 'exact_s18_target_required'}
 $queue=[Collections.Generic.Queue[IO.DirectoryInfo]]::new()
 $queue.Enqueue([IO.DirectoryInfo]::new($base))
 [long]$logical=0;[long]$allocated=0;[long]$rootLogical=0;[long]$rootAllocated=0
 [int]$files=0;[int]$entries=0;[int]$skipped=0
 $started=[DateTimeOffset]::UtcNow
 $ownRoot=(Join-Path $base 'root')+[IO.Path]::DirectorySeparatorChar
 while($queue.Count){
  if(([DateTimeOffset]::UtcNow-$started).TotalSeconds -gt 25){throw 'resource_sample_timeout'}
  $directory=$queue.Dequeue()
  try{$children=$directory.GetFileSystemInfos()}catch{
   if(Test-S18GoneTargetError $_.Exception $directory.FullName $compiler){$skipped++;continue};throw
  }
  foreach($entry in $children){
   $entries++;if($entries -gt 200000){throw 'resource_sample_entry_cap'}
   if(($entries -band 127) -eq 0 -and ([DateTimeOffset]::UtcNow-$started).TotalSeconds -gt 25){throw 'resource_sample_timeout'}
   try{$attributes=[IO.File]::GetAttributes($entry.FullName)}catch{
    if(Test-S18GoneTargetError $_.Exception $entry.FullName $compiler){$skipped++;continue};throw
   }
   if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'resource_reparse_refused'}
   if($attributes -band [IO.FileAttributes]::Directory){$queue.Enqueue([IO.DirectoryInfo]::new($entry.FullName));continue}
   try{
    $stream=[IO.File]::Open($entry.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{$storage=[PiS13EvidenceStorageV1]::Inspect($stream)}finally{$stream.Dispose()}
   }catch{if(Test-S18GoneTargetError $_.Exception $entry.FullName $compiler){$skipped++;continue};throw}
   $files++;$logical+=$storage.EndOfFile;$allocated+=$storage.AllocationSize
   if($entry.FullName.StartsWith($ownRoot,[StringComparison]::OrdinalIgnoreCase)){$rootLogical+=$storage.EndOfFile;$rootAllocated+=$storage.AllocationSize}
  }
 }
 return @{logical_bytes=$logical;allocation_bytes=$allocated;root_logical_bytes=$rootLogical;root_allocation_bytes=$rootAllocated;files=$files;skipped_vanished_target_entries=$skipped;scope='non-atomic read-only sampling; vanished compiler target entries only; 512MiB headroom mandatory'}
}
Export-ModuleMember -Function Test-S18GoneTargetError,Get-S18ResourceSnapshot
