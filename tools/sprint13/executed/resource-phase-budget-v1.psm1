# SOURCE-ONLY: admission for a NEW full uncompressed fixture phase, not production budgets.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Read-PhaseBudgetProof($Pin){
 Assert-OwnedNoReparse $Pin.path;Assert-OwnedHash $Pin.path $Pin.sha256
 if((Get-Item -LiteralPath $Pin.path).Length -gt 4MB){throw 'phase_budget_proof_size'}
 Assert-OwnedPrivateDirectory (Split-Path -Parent $Pin.path)
 return Get-Content -LiteralPath $Pin.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
}
function Get-PhaseBudgetLogical([string[]]$Roots){
 $sum=0L;$count=0;$stack=[Collections.Generic.Stack[string]]::new()
 foreach($r in $Roots){if(Test-Path -LiteralPath $r){$stack.Push($r)}}
 while($stack.Count){$dir=$stack.Pop();Assert-OwnedNoReparse $dir
  foreach($f in Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop){
   if(++$count -gt 100000){throw 'phase_budget_namespace_count'}
   # Known meter-only fixture junction is never traversed by a logical pass.
   if($f.Attributes -band [IO.FileAttributes]::ReparsePoint){
    $known=Join-Path $PSScriptRoot '../../.local/sprint13/root/runner-regression01/reparse-link'
    if((Get-OwnedCanonicalPath $f.FullName) -cne (Get-OwnedCanonicalPath $known)){throw 'phase_budget_unknown_reparse'}
    continue
   }
   if($f.PSIsContainer){$stack.Push($f.FullName)}else{$sum+=$f.Length}
  }
 }
 return $sum
}
function New-S13PhaseBudget {
 param([hashtable]$Config,[string]$ConfigPath,[string]$ConfigSha,[string]$PhasePath,[DateTime]$Deadline,[DateTime]$Started)
 $b=$Config.phase_budget;$root=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../../.local/sprint13')
 $out=Get-OwnedCanonicalPath $Config.output_directory;$install=Get-OwnedCanonicalPath $Config.install_parent
 foreach($p in @($out,$install)){if(!$p.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'phase_budget_fixed_S13_scope'}}
 Assert-OwnedNoReparse $out
 # Expand-OwnedPackage must create this NEW directory only after admission.
 # Validate its existing parent without trying to open a nonexistent target.
 if(Test-Path -LiteralPath $install){throw 'phase_budget_install_must_be_new'}
 Assert-OwnedNoReparse (Split-Path -Parent $install)
 Assert-OwnedPrivateDirectory $out
 $expected=@(@('owned-runtime.psm1',$Config.module_sha),@('evidence-storage.psm1','F8368FBE5008E657BCE45DF25CDDB8F40D80AA69A9405A9B26D2A9BCC5B01E87'),@('evidence-meter.psm1','8EE98A818BF677808E92DFBFB2B6EB08CFA721ACEFB963CF98AA16EA204EC567'),@('resource-phase-budget.psm1',$b.module_sha))
 foreach($p in $expected){Assert-OwnedHash (Join-Path $PSScriptRoot $p[0]) $p[1]}
 Assert-OwnedHash $ConfigPath $ConfigSha;Assert-OwnedHash $PhasePath $b.phase_sha
 $decisionPath=Get-OwnedCanonicalPath (Join-Path $root 'root/resource-decision04.json')
 if((Get-OwnedCanonicalPath $b.decision.path) -cne $decisionPath -or $b.decision.sha256.ToUpperInvariant() -cne '60A80999941A505BDBD675DEFAF6DCD0104E905A3ADDA6927C24B08F37999244'){throw 'phase_budget_exact_adopted_decision'}
 $d=Read-PhaseBudgetProof $b.decision
 if($d.verdict -cne 'ADOPTED_S13_REMAINDER_STORAGE_CAPS' -or $d.scope -cne 'S13_REMAINDER_NO_ADDITIONAL_COMPRESSION' -or $d.strategy -cne 'FRESH_ALL_FILES_PLUS_FULL_UNCOMPRESSED_PHASE_PEAK_V1' -or !$d.no_additional_compression_authority -or $d.allocated_limit -ne 40GB -or $d.logical_limit -ne 40GB -or $d.metric -cne 'FileStandardInfo.AllocationSize' -or $d.proposal_sha256 -cne '1F66552619C25BD2CAE3E7713BDF1DB57A8069067553ED413D76B8E3AC34C430' -or @($d.votes).Count -ne 5 -or (@($d.votes.member_id|Sort-Object)-join ',') -cne 'Customer,PM,QA,Root,TD'){throw 'phase_budget_actual_five_role_caps'}
 foreach($v in $d.votes){$r=Read-PhaseBudgetProof $v.record;if($v.vote -cne 'FOR' -or $r.vote -cne 'FOR' -or $r.author_role -cne $v.member_id -or $r.proposal_sha256 -cne $d.proposal_sha256 -or $r.allocated_limit -ne 40GB -or $r.logical_limit -ne 40GB -or $r.strategy -cne $d.strategy -or !$r.no_additional_compression_authority){throw 'phase_budget_actual_authored_FOR'}}
 foreach($n in @('capture_reservation_bytes','phase_reservation_bytes','phase_allocation_reservation_bytes')){if($Config[$n] -isnot [long] -and $Config[$n] -isnot [int]){throw 'phase_budget_integer_reservation'}}
 if($b.db_wal_temp_extract_archive_bytes -lt 1536MB -or $Config.phase_reservation_bytes -lt ($Config.capture_reservation_bytes+$b.db_wal_temp_extract_archive_bytes) -or $Config.phase_reservation_bytes -gt 8GB -or $Config.phase_allocation_reservation_bytes -lt ($Config.phase_reservation_bytes+128MB)){throw 'phase_budget_full_uncompressed_peak_and_rounding'}
 foreach($role in @('Root','QA','TD')){
  $r=Read-PhaseBudgetProof $b.reviews[$role]
  # Bind actual budget fields, not a circular configSHA->reviewSHA->configSHA.
  if($r.author_role -cne $role -or $r.verdict -cne 'PROSPECTIVE_EXACT_FULL_UNCOMPRESSED_PHASE_RESOURCE_GO' -or $r.scope -cne $Config.scope -or $r.package_sha256.ToUpperInvariant() -cne $Config.package_sha.ToUpperInvariant() -or $r.output_directory -cne $out -or $r.install_parent -cne $install -or $r.capture_reservation_bytes -ne $Config.capture_reservation_bytes -or $r.phase_sha256.ToUpperInvariant() -cne $b.phase_sha.ToUpperInvariant() -or $r.budget_module_sha256.ToUpperInvariant() -cne $b.module_sha.ToUpperInvariant() -or $r.phase_reservation_bytes -ne $Config.phase_reservation_bytes -or $r.phase_allocation_reservation_bytes -ne $Config.phase_allocation_reservation_bytes -or $r.db_wal_temp_extract_archive_bytes -ne $b.db_wal_temp_extract_archive_bytes -or !$r.all_other_writers_quiet){throw 'phase_budget_independent_exact_peak_review'}
 }
 Import-Module (Join-Path $PSScriptRoot 'evidence-storage.psm1') -Force -DisableNameChecking
 Import-Module (Join-Path $PSScriptRoot 'evidence-meter.psm1') -Force -DisableNameChecking
 if([DateTime]::UtcNow -ge $Deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'phase_budget_before_creation_free_floor'}
 $m=Get-S13EvidenceInventory -DeadlineUtc $Deadline -MaxFiles 100000
 $ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
 foreach($r in $m.files){$ordered.Add($r.path,$r)}
 $path=Join-Path $out 'phase-fresh-native-baseline.jsonl';$s=$null;$sha=[Security.Cryptography.SHA256]::Create();$bytes=0L
 try{$s=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  foreach($r in $ordered.Values){$w=$r.witness;$ci=$w.FileCompressionInfo
   $row=@('s13-native-inventory-v1',$r.path,$r.relative_path,$w.VolumeId,$w.FileId,[string]$w.Links,[string]$w.EndOfFile,[string]$w.AllocationSize,[string]$w.Attributes,$w.FileSystem,[string]$w.FileSystemFlags,$w.FinalPath,[string]$w.CompressionFormat,[string]$ci.CompressedFileSize,[string]$ci.CompressionUnitShift,[string]$ci.ChunkShift,[string]$ci.ClusterShift,[string]$ci.Reserved0,[string]$ci.Reserved1,[string]$ci.Reserved2)
   $raw=[Text.UTF8Encoding]::new($false).GetBytes(($row|ConvertTo-Json -Compress)+"`n");$bytes+=$raw.Length;if($bytes -gt 64MB -or [DateTime]::UtcNow -ge $Deadline){throw 'phase_budget_inventory_capture_limit'}
   [void]$sha.TransformBlock($raw,0,$raw.Length,$raw,0);$s.Write($raw,0,$raw.Length)
  };[void]$sha.TransformFinalBlock([byte[]]::new(0),0,0);$digest=[Convert]::ToHexString($sha.Hash);$s.Flush($true)
 }finally{if($s){$s.Dispose()};$sha.Dispose()}
 $m.Remove('files');$m.inventory_sha256=$digest;$m.inventory_bytes=$bytes;$m.inventory_path=$path
 $fixed=160MB+256MB+256MB
 $logical=[decimal]$m.logical_bytes+$Config.phase_reservation_bytes+$fixed
 $allocated=[decimal]$m.allocated_bytes+$Config.phase_allocation_reservation_bytes+$fixed
 $proof=@{scope=$Config.scope;native_baseline=$m;full_uncompressed_phase_logical=$Config.phase_reservation_bytes;full_uncompressed_phase_allocation=$Config.phase_allocation_reservation_bytes;fixed_reserves=@{metadata=160MB;public=256MB;unmetered_directory_MFT=256MB};logical_upper_bound=$logical;allocated_upper_bound=$allocated;compression_savings_credit=0;not_fresh_active_PG_aggregate=$true;root=$root;out=$out;install=$install;deadline=$Deadline;started=$Started;capture_reservation=$Config.capture_reservation_bytes;phase_reservation=$Config.phase_reservation_bytes;decision_sha256=$b.decision.sha256;config_sha256=$ConfigSha}
 Write-OwnedJson (Join-Path $out 'phase-fresh-native-baseline-summary.json') $proof
 if($logical -ge 40GB -or $allocated -ge 40GB -or [decimal]([IO.DriveInfo]::new('C').AvailableFreeSpace)-$Config.phase_allocation_reservation_bytes-$fixed -lt 4GB){throw 'phase_budget_fresh_whole_uncompressed_peak_does_not_fit'}
 return $proof
}
function Assert-S13PhaseBudget {
 param([hashtable]$Proof,[long]$Next=0)
 if($Next -lt 0 -or [DateTime]::UtcNow -ge $Proof.deadline -or ([DateTime]::UtcNow-$Proof.started).TotalSeconds -ge 1800 -or [decimal]([IO.DriveInfo]::new('C').AvailableFreeSpace)-$Next -lt 4GB){throw 'phase_budget_next_floor_or_deadline'}
 $phase=Get-PhaseBudgetLogical @($Proof.out,$Proof.install)
 # Other writers stay quiet throughout this fixture. Charge the complete initial
 # GLOBAL native inventory plus ALL current own output/install bytes and NEXT.
 # Initial own output is deliberately double-counted; never subtract old bytes.
 # Rewalking the entire retained evidence tree before every SQL command is not
 # required to maintain this conservative bound and can exhaust the phase timer.
 $global=[decimal]$Proof.native_baseline.logical_bytes+$phase
 if([DateTime]::UtcNow -ge $Proof.deadline -or ([DateTime]::UtcNow-$Proof.started).TotalSeconds -ge 1800){throw 'phase_budget_scan_deadline'}
 if($phase+$Next -gt $Proof.phase_reservation -or $global+$Next+160MB+256MB+256MB -ge 40GB -or $Proof.allocated_upper_bound -ge 40GB){throw 'phase_budget_actual_logical_or_full_reserved_allocation'}
}
Export-ModuleMember -Function New-S13PhaseBudget,Assert-S13PhaseBudget
<# SOURCE ONLY. A fresh complete native meter BEFORE package/PG creation is mandatory.
Every failed capture remains charged. Exact whole-phase uncompressed captures, DB,
WAL,temp,extract and archives reserved independently; minimum1536MiB is not a fit
claim. Allocation additionally reserves128MiB rounding; fixed160metadata+256public
+256unmetered directory/MFT charged to both caps. No compressed ratio or IOCTL1GiB
peak reused. All other writers quiet remains an externally reviewed precondition.
While PG active only logical reads plus conservative initial+FULLphase allocation
upper bound; no fresh physical PG aggregate or whole-C-volume claim. Existing known
regression junction not traversed; native initial meter validates its exact identity.
No SQL, process, permission or production5/2/10 modification supplied by this module.
#>
