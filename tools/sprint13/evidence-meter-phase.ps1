param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# Read-only measurement under the ORIGINAL logical16GiB cap. No compression.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'meter_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in @(@('owned-runtime.psm1',$c.module_sha),@('evidence-storage.psm1',$c.storage_sha),@('evidence-meter.psm1',$c.meter_sha))){if((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $pin[0])).Hash -cne $pin[1].ToUpperInvariant()){throw 'meter_module_before_import'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-readonly-native-allocation-measurement' -or $c.original_logical_limit -ne 16GB -or $c.metadata_reservation -ne 160MB -or $c.public_supplement_reservation -ne 256MB){throw 'meter_finite_original_budget_scope'}
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$freeze=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($freeze -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or [DateTime]::UtcNow -ge $freeze -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'meter_admission_freeze_capacity'}
Import-Module (Join-Path $PSScriptRoot 'evidence-storage.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'evidence-meter.psm1') -Force -DisableNameChecking
$end=[DateTime]::UtcNow.AddSeconds(120);if($freeze -lt $end){$end=$freeze}
$actual=Get-S13EvidenceInventory -DeadlineUtc $end
if([decimal]$actual.logical_bytes+$c.metadata_reservation+$c.public_supplement_reservation -gt 16GB){throw 'meter_original_logical_cap_and_reserved_receipts'}
$inventory=Join-Path $out 'all-s13-native-inventory.jsonl';$f=[IO.File]::Open($inventory,'CreateNew','Write','None');$bytes=0L
$ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($entry in $actual.files){$ordered.Add($entry.path,$entry)}
try{foreach($entry in $ordered.Values){
 $w=$entry.witness;$ci=$w.FileCompressionInfo
 # Same lossless native fields as the compression phase's canonical inventory.
 # Constant property names and duplicate derived identity are represented by schema.
 $row=@('s13-native-inventory-v1',$entry.path,$entry.relative_path,$w.VolumeId,$w.FileId,[string]$w.Links,[string]$w.EndOfFile,[string]$w.AllocationSize,[string]$w.Attributes,$w.FileSystem,[string]$w.FileSystemFlags,$w.FinalPath,[string]$w.CompressionFormat,[string]$ci.CompressedFileSize,[string]$ci.CompressionUnitShift,[string]$ci.ChunkShift,[string]$ci.ClusterShift,[string]$ci.Reserved0,[string]$ci.Reserved1,[string]$ci.Reserved2)
 $line=[Text.UTF8Encoding]::new($false).GetBytes(($row|ConvertTo-Json -Compress)+"`n");$bytes+=$line.Length;if($bytes -gt 64MB){throw 'meter_inventory_receipt_bound'};$f.Write($line,0,$line.Length)
};$f.Flush($true)}finally{$f.Dispose()}
$actual.Remove('files');$actual.status='S13_NATIVE_ALLOCATION_MEASUREMENT_PENDING_QA_TD';$actual.inventory_path=$inventory;$actual.inventory_sha256=Get-OwnedHash $inventory;$actual.inventory_bytes=$bytes
$actual.inventory_schema='s13-native-inventory-v1 fixed20field stringarray rows sorted fullpath Ordinal, UTF8 LF'
$actual.original_logical_limit=16GB;$actual.new_caps_not_adopted=$true;$actual.no_compression_called=$true;$actual.metadata_reservation_bytes=$c.metadata_reservation;$actual.public_supplement_reservation_bytes=$c.public_supplement_reservation
Write-OwnedJson (Join-Path $out 'meter-result.json') $actual
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Assert-OwnedHash $PhaseConfig $PhaseConfigSha
