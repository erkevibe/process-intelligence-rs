param([Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root=[IO.Path]::GetFullPath((Join-Path $workspace '.local/sprint16'))
$out=[IO.Path]::GetFullPath($OutputPath)
if(!$out.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'fresh_s16_receipt_required'}
# Inspection only. Never calls Set/SetCompression or changes existing files.
Import-Module (Join-Path $workspace 'tools/sprint15/evidence-storage.psm1') -Force -DisableNameChecking
$started=[DateTimeOffset]::UtcNow
$totals=@{}
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force)
foreach($f in $files){
 if(([DateTimeOffset]::UtcNow-$started).TotalMinutes -gt 5){throw 'measurement_timeout'}
 if($f.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse_refused'}
 $relative=[IO.Path]::GetRelativePath($root,$f.FullName)
 $owner=$relative.Split([IO.Path]::DirectorySeparatorChar)[0]
 if(!$totals.ContainsKey($owner)){$totals[$owner]=@{files=0L;logical_bytes=0L;allocation_bytes=0L;compressed_file_bytes=0L;multiple_link_files=0L}}
 $stream=[IO.File]::Open($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{$w=[PiS13EvidenceStorageV1]::Inspect($stream)}finally{$stream.Dispose()}
 if($w.EndOfFile -ne $f.Length){throw 'concurrent_file_size_change_retry_after_quiescence'}
 $row=$totals[$owner];$row.files++;$row.logical_bytes+=$w.EndOfFile;$row.allocation_bytes+=$w.AllocationSize;$row.compressed_file_bytes+=$w.FileCompressionInfo.CompressedFileSize
 if($w.Links -gt 1){$row.multiple_link_files++}
}
[long]$logical=0;[long]$allocated=0
foreach($row in $totals.Values){$logical+=$row.logical_bytes;$allocated+=$row.allocation_bytes}
$free=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root)).AvailableFreeSpace
$ownerCaps=@{root=3GB;service=4GB}
$ownerOk=$true
foreach($owner in $ownerCaps.Keys){if($totals.ContainsKey($owner)){$row=$totals[$owner];if($row.logical_bytes -gt $ownerCaps[$owner] -or $row.allocation_bytes -gt $ownerCaps[$owner]){$ownerOk=$false}}}
$proof=@{utc=[DateTimeOffset]::UtcNow.ToString('o');scope='S16 only; read-only per-file native sampling, not atomic filesystem snapshot or old-install inventory';logical_bytes=$logical;allocation_bytes=$allocated;free_bytes=$free;owners=$totals;owner_caps=$ownerCaps;within_owner_caps=$ownerOk;within_total_8GiB=($logical -le 8GB -and $allocated -le 8GB);free_floor_8GiB=($free -ge 8GB);set_compression_called=$false}
$json=$proof|ConvertTo-Json -Depth 8
$file=[IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes($json);$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}
Write-Output $json
if(!$proof.within_total_8GiB -or !$proof.free_floor_8GiB -or !$proof.within_owner_caps){exit 1}
