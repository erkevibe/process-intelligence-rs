param([Parameter(Mandatory)][string]$Directory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $workspace 'tools/sprint20/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $workspace 'tools/sprint15/evidence-storage.psm1') -Force
Import-Module (Join-Path $workspace 'tools/sprint20/capacity-storage.psm1') -Force
Import-Module (Join-Path $workspace 'tools/sprint20/continuation-resource-guard.psm1') -Force
$out=New-OwnedPrivateDirectory $Directory
$small=New-OwnedPrivateDirectory (Join-Path $out 'small')
$own=New-OwnedPrivateDirectory (Join-Path $small 'root')
[void](New-OwnedPrivateDirectory (Join-Path $own 'target'))
$rows=@();$total=0L;$allocated=0L
foreach($case in @(@{name='empty';length=0;compress=$false},@{name='one';length=1;compress=$false},@{name='cluster';length=4096;compress=$false},@{name='next-cluster';length=4097;compress=$false},@{name='compressed';length=1MB;compress=$true})){
 $path=Join-Path $own ($case.name+'.bin')
 $stream=[IO.File]::Open($path,'CreateNew','ReadWrite','ReadWrite')
 try{
  if($case.length){$stream.Write([byte[]]::new($case.length));$stream.Flush($true)}
  if($case.compress){$operation=[PiS13EvidenceStorageV1]::Set($stream,1);if(!$operation.ApiReturnedTrue){throw 'actual_compression_calibration_failed'}}
  $before=[PiS13EvidenceStorageV1]::Inspect($stream)
  $fast=[PiS20CapacityStorage]::Inspect($stream)
  $after=[PiS13EvidenceStorageV1]::Inspect($stream)
  if($before.EndOfFile -ne $fast.EndOfFile -or $before.AllocationSize -ne $fast.AllocationSize -or $after.EndOfFile -ne $fast.EndOfFile -or $after.AllocationSize -ne $fast.AllocationSize -or $fast.EndOfFile -ne $case.length){throw 'actual_native_counter_equivalence'}
  # Request DEFAULT(1); NTFS reports the concrete LZNT1 format(2).
  if($case.compress -and ($before.CompressionFormat -ne 2 -or $fast.AllocationSize -ge $fast.EndOfFile)){throw 'actual_ntfs_compression_not_observed'}
  $rows+=@{name=$case.name;logical=$fast.EndOfFile;allocated=$fast.AllocationSize;old_native_equal=$true;requested_compression_format=$(if($case.compress){1}else{0});observed_compression_format=$before.CompressionFormat}
  $total+=$fast.EndOfFile;$allocated+=$fast.AllocationSize
 }finally{$stream.Dispose()}
}
$sample=Get-S20ResourceSnapshot $small (Join-Path $own 'target')
if($sample.files -ne 5 -or $sample.logical_bytes -ne $total -or $sample.allocation_bytes -ne $allocated -or $sample.root_logical_bytes -ne $total -or $sample.root_allocation_bytes -ne $allocated){throw 'small_tree_exact_capacity'}
$link=Join-Path $own 'link.bin';$linkCreated=$false
try{[void][IO.File]::CreateSymbolicLink($link,(Join-Path $own 'one.bin'));$linkCreated=$true}catch [UnauthorizedAccessException]{}catch [IO.IOException]{}
$reparse='SKIPPED_OS_REFUSED_SYMLINK_CREATION'
if($linkCreated){
 $refused=$false
 try{[void](Get-S20ResourceSnapshot $small (Join-Path $own 'target'))}catch{if($_.Exception.Message -match 'resource_reparse_refused'){$refused=$true}else{throw}}
 if(!$refused){throw 'actual_reparse_not_refused'}
 $reparse='ACTUAL_SYMLINK_REFUSED'
 [IO.File]::Delete($link)
}
$watch=[Diagnostics.Stopwatch]::StartNew()
$full=Get-S20ResourceSnapshot (Join-Path $workspace '.local/sprint20') (Join-Path $workspace '.local/sprint20/root/target')
$watch.Stop()
if($watch.ElapsedMilliseconds -gt 25000 -or $full.logical_bytes -gt (12GB-512MB) -or $full.allocation_bytes -gt (12GB-512MB) -or $full.root_logical_bytes -gt (8GB-512MB) -or $full.root_allocation_bytes -gt (8GB-512MB) -or (Get-PSDrive C).Free -lt 8GB){throw 'actual_full_scan_budget'}
Write-OwnedJson (Join-Path $out 'result.json') @{status='ACTUAL_NATIVE_CAPACITY_COUNTER_EQUIVALENCE_AND_FULL_25S_SCAN_PASS';native_cases=$rows;small_tree=$sample;reparse_test=$reparse;full_tree=$full;elapsed_ms=$watch.ElapsedMilliseconds;free_bytes=(Get-PSDrive C).Free;utc=[DateTimeOffset]::UtcNow.ToString('o');no_native_feature_engine_executed=$true}
