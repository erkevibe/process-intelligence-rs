# Read-only bounded sampling; compiler-target and exact owned PG init-cache races.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../sprint20/capacity-storage.psm1') -Force
$ErrorActionPreference='Stop'
function Test-S20GoneTargetError([Exception]$Error,[string]$Path,[string]$Target) {
 $full=[IO.Path]::GetFullPath($Path)
 $prefix=[IO.Path]::GetFullPath($Target).TrimEnd('\')+[IO.Path]::DirectorySeparatorChar
 $cause=$Error.GetBaseException()
 if(!$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
  !($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException] -or $cause -is [UnauthorizedAccessException])){return $false}
 try{[void][IO.File]::GetAttributes($full);return $false}catch{
  $current=$_.Exception.GetBaseException()
  return $current -is [IO.FileNotFoundException] -or $current -is [IO.DirectoryNotFoundException]
 }
}
function Test-S21GonePgInternalInitError([Exception]$Error,[string]$Path,[string]$Root){
 $full=[IO.Path]::GetFullPath($Path)
 $trustedBase=Join-Path ([IO.Path]::GetFullPath($Root)) 'root/pgdata11/base'
 $relative=[IO.Path]::GetRelativePath($trustedBase,$full)
 # Canonical nonzero decimal database OID, one exact basename, no extra components.
 if($relative -cnotmatch '^[1-9][0-9]*[\\/]pg_internal\.init$'){return $false}
 [uint32]$oid=0
 if(![uint32]::TryParse(($relative -split '[\\/]',2)[0],[ref]$oid)){return $false}
 $cause=$Error.GetBaseException()
 if($cause -isnot [IO.FileNotFoundException] -and $cause -isnot [IO.DirectoryNotFoundException]){return $false}
 $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')
 $parent=[IO.DirectoryInfo]::new((Split-Path -Parent $full))
 while($parent){
  try{$attributes=[IO.File]::GetAttributes($parent.FullName)}catch{return $false}
  if($attributes -band [IO.FileAttributes]::ReparsePoint -or !($attributes -band [IO.FileAttributes]::Directory)){return $false}
  if($parent.FullName.Equals($rootPath,[StringComparison]::OrdinalIgnoreCase)){break}
  $parent=$parent.Parent
 }
 if(!$parent){return $false}
 # A denied, existing or reparse node is never skipped. Only a second genuine
 # absence observation may authorize this narrow non-atomic sampler exception.
 try{[void][IO.File]::GetAttributes($full);return $false}catch{
  $current=$_.Exception.GetBaseException()
  return $current -is [IO.FileNotFoundException] -or $current -is [IO.DirectoryNotFoundException]
 }
}
function Get-S20ResourceSnapshot([string]$Root,[string]$Target) {
 $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
 $compiler=[IO.Path]::GetFullPath($Target)
 if(!$compiler.Equals((Join-Path $base 'root/target'),[StringComparison]::OrdinalIgnoreCase)){throw 'exact_s21_target_required'}
 $queue=[Collections.Generic.Queue[IO.DirectoryInfo]]::new()
 $queue.Enqueue([IO.DirectoryInfo]::new($base))
 [long]$logical=0;[long]$allocated=0;[long]$rootLogical=0;[long]$rootAllocated=0
 [int]$files=0;[int]$entries=0;[int]$skipped=0
 [int]$skippedPgInit=0
 $started=[DateTimeOffset]::UtcNow
 $ownRoot=(Join-Path $base 'root')+[IO.Path]::DirectorySeparatorChar
 while($queue.Count){
  if(([DateTimeOffset]::UtcNow-$started).TotalSeconds -gt 25){throw 'resource_sample_timeout'}
  $directory=$queue.Dequeue()
  try{$children=$directory.GetFileSystemInfos()}catch{
   if(Test-S20GoneTargetError $_.Exception $directory.FullName $compiler){$skipped++;continue};throw
  }
  foreach($entry in $children){
   $entries++;if($entries -gt 200000){throw 'resource_sample_entry_cap'}
   if(($entries -band 127) -eq 0 -and ([DateTimeOffset]::UtcNow-$started).TotalSeconds -gt 25){throw 'resource_sample_timeout'}
   try{$attributes=[IO.File]::GetAttributes($entry.FullName)}catch{
    if(Test-S20GoneTargetError $_.Exception $entry.FullName $compiler){$skipped++;continue}
    if(Test-S21GonePgInternalInitError $_.Exception $entry.FullName $base){$skippedPgInit++;continue};throw
   }
   if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'resource_reparse_refused'}
   if($attributes -band [IO.FileAttributes]::Directory){$queue.Enqueue([IO.DirectoryInfo]::new($entry.FullName));continue}
   try{
    $storage=[PiS20CapacityStorage]::InspectPath($entry.FullName)
   }catch{
    if(Test-S20GoneTargetError $_.Exception $entry.FullName $compiler){$skipped++;continue}
    if(Test-S21GonePgInternalInitError $_.Exception $entry.FullName $base){$skippedPgInit++;continue};throw
   }
   $files++;$logical+=$storage.EndOfFile;$allocated+=$storage.AllocationSize
   if($entry.FullName.StartsWith($ownRoot,[StringComparison]::OrdinalIgnoreCase)){$rootLogical+=$storage.EndOfFile;$rootAllocated+=$storage.AllocationSize}
  }
 }
 return @{logical_bytes=$logical;allocation_bytes=$allocated;root_logical_bytes=$rootLogical;root_allocation_bytes=$rootAllocated;files=$files;skipped_vanished_target_entries=$skipped;skipped_vanished_pg_internal_init_entries=$skippedPgInit;scope='non-atomic read-only sampling; vanished compiler-target entries or exact owned pgdata11/base/nonzero-decimal-OID/pg_internal.init only; second genuine absence required; 512MiB headroom mandatory'}
}
Export-ModuleMember -Function Test-S20GoneTargetError,Test-S21GonePgInternalInitError,Get-S20ResourceSnapshot
