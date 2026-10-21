param([Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root=Join-Path $workspace '.local/sprint18/service'
$out=[IO.Path]::GetFullPath($OutputPath)
if(!$out.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)){throw 'fresh_service_receipt_required'}
# Inspection only: native FileStandardInfo.AllocationSize, no mutation/compression.
Import-Module (Join-Path $workspace 'tools/sprint15/evidence-storage.psm1') -Force -DisableNameChecking
$started=[DateTimeOffset]::UtcNow
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force)
$logical=0L;$allocated=0L;$links=0L;$inventory=@()
foreach($f in $files){
 if(([DateTimeOffset]::UtcNow-$started).TotalMinutes -gt 3){throw 'native_measurement_timeout'}
 if($f.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'service_reparse_refused'}
 $stream=[IO.File]::Open($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{$w=[PiS13EvidenceStorageV1]::Inspect($stream)}finally{$stream.Dispose()}
 if($w.EndOfFile -ne $f.Length){throw 'concurrent_service_file_change'}
 $logical+=$w.EndOfFile;$allocated+=$w.AllocationSize
 if($w.Links -gt 1){$links++}
 $inventory+=,@{relative=[IO.Path]::GetRelativePath($root,$f.FullName);logical_bytes=$w.EndOfFile;allocation_bytes=$w.AllocationSize;links=$w.Links;file_id=$w.FileId;volume_id=$w.VolumeId}
}
$free=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root)).AvailableFreeSpace
$proof=@{schema_version=1;utc=[DateTimeOffset]::UtcNow.ToString('o');scope='S18 service only, read-only per-file native sampling after own native processes closed; receipt itself excluded, not an atomic filesystem snapshot';metric='FileStandardInfo.AllocationSize';files=$files.Count;logical_bytes=$logical;allocation_bytes=$allocated;multiple_link_files=$links;free_bytes=$free;within_service_2GiB=($logical -le 2GB -and $allocated -le 2GB);free_floor_8GiB=($free -ge 8GB);set_compression_called=$false;inventory=$inventory}
$stream=[IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($proof|ConvertTo-Json -Depth 8));$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
Write-Output (@{files=$files.Count;logical_bytes=$logical;allocation_bytes=$allocated;free_bytes=$free;within_service_2GiB=$proof.within_service_2GiB;free_floor_8GiB=$proof.free_floor_8GiB;proof_sha256=(Get-FileHash $out).Hash}|ConvertTo-Json)
if(!$proof.within_service_2GiB -or !$proof.free_floor_8GiB){exit 1}
