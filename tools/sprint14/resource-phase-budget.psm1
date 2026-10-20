# S14 draft: NEW-namespace admission, separate retained S13 bound, no old guard edits.
# Actual adopted decision, all five authored votes and majority are rechecked per phase.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Read-PhaseBudgetProof($Pin){
 Assert-OwnedNoReparse $Pin.path;Assert-OwnedHash $Pin.path $Pin.sha256
 if((Get-Item -LiteralPath $Pin.path).Length -gt 4MB){throw 'phase_budget_proof_size'}
 Assert-OwnedPrivateDirectory (Split-Path -Parent $Pin.path)
 return Get-Content -LiteralPath $Pin.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
}
function Get-PhaseBudgetLogical([string[]]$Roots,[hashtable]$Proof,[bool]$Final=$false){
 $sum=0L;$count=0;$stack=[Collections.Generic.Stack[string]]::new()
 $groups=@{install=0L;inventory=0L;outer=0L;capture=0L;other=0L}
 $outerNames=@('child.stdout','child.stderr','runner.stdout','runner.stderr')
 $captureNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($name in $Proof.capture_files){[void]$captureNames.Add($name)}
 foreach($r in $Roots){if(Test-Path -LiteralPath $r){$stack.Push($r)}}
 while($stack.Count){$dir=$stack.Pop();Assert-OwnedNoReparse $dir
  foreach($f in Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop){
   if(++$count -gt 160000){throw 'phase_budget_namespace_count'}
   # Known meter-only fixture junction is never traversed by a logical pass.
   if($f.Attributes -band [IO.FileAttributes]::ReparsePoint){
    $known=Join-Path $PSScriptRoot '../../.local/sprint14/root/runner-regression01/reparse-link'
    if((Get-OwnedCanonicalPath $f.FullName) -cne (Get-OwnedCanonicalPath $known)){throw 'phase_budget_unknown_reparse'}
    continue
   }
   if($f.PSIsContainer){$stack.Push($f.FullName)}else{
    $sum+=$f.Length
    # The ENTIRE install, including service metadata, is charged to its explicit
    # DB/WAL/temp/extract/archive reserve. No extension-based install exclusions.
    if($f.FullName.StartsWith($Proof.install.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$groups.install+=$f.Length}
    elseif($f.FullName.StartsWith($Proof.out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
     if($f.FullName -ieq (Join-Path $Proof.out 'phase-fresh-native-baseline.jsonl')){$groups.inventory+=$f.Length}
     elseif($f.DirectoryName -ieq $Proof.out -and $f.Name -cin $outerNames){if($f.Length -gt 16MB){throw 'phase_budget_outer_stream_max'};$groups.outer+=$f.Length}
     elseif($f.DirectoryName -ieq $Proof.out -and $captureNames.Contains($f.Name)){$groups.capture+=$f.Length}
     else{$groups.other+=$f.Length}
    }else{throw 'phase_budget_unclassified_path'}
   }
  }
 }
 $otherCap=if($Final){64MB}else{32MB}
 if($groups.install -gt $Proof.install_reservation -or $groups.capture -gt $Proof.capture_reservation -or $groups.inventory -gt 128MB -or $groups.outer -gt 64MB -or $groups.other -gt $otherCap){throw 'phase_budget_install_capture_or_metadata_reservation'}
 # 32MiB OTHER remains reserved for bounded finalization records after the last
 # in-phase guard; the separate closed-phase receipt must prove final OTHER<=64.
 if($Final){return @{total_bytes=$sum;groups=$groups;other_final_cap=64MB;inventory_cap=128MB;four_outer_streams_cap=64MB;metadata_total_cap=256MB}}
 return $sum
}
function New-S14PhaseBudget {
 param([hashtable]$Config,[string]$ConfigPath,[string]$ConfigSha,[string]$PhasePath,[DateTime]$Deadline,[DateTime]$Started)
 $b=$Config.phase_budget;$root=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../../.local/sprint14')
 $out=Get-OwnedCanonicalPath $Config.output_directory;$install=Get-OwnedCanonicalPath $Config.install_parent
 foreach($p in @($out,$install)){if(!$p.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'phase_budget_fixed_S14_scope'}}
 Assert-OwnedNoReparse $out
 # Expand-OwnedPackage must create this NEW directory only after admission.
 # Validate its existing parent without trying to open a nonexistent target.
 if(Test-Path -LiteralPath $install){throw 'phase_budget_install_must_be_new'}
 Assert-OwnedNoReparse (Split-Path -Parent $install)
 Assert-OwnedPrivateDirectory $out
 $expected=@(@('owned-runtime.psm1',$Config.module_sha),@('evidence-storage.psm1','46E6C27F7E173D51A7B0AE6A268AB2194B917E257F33A79B5389BFF71C8DBF29'),@('evidence-meter.psm1','A558BD2F5C545978AEE19E36D01BA9AC75B449F4CEED33BBA732037D2C6AB93E'),@('resource-phase-budget.psm1',$b.module_sha))
 foreach($p in $expected){Assert-OwnedHash (Join-Path $PSScriptRoot $p[0]) $p[1]}
 Assert-OwnedHash $ConfigPath $ConfigSha;Assert-OwnedHash $PhasePath $b.phase_sha
 $decisionPath=Get-OwnedCanonicalPath (Join-Path $root 'root/start-decision01.json')
 $proposalPath=Get-OwnedCanonicalPath (Join-Path $root 'root/start-proposal01.json')
 if((Get-OwnedCanonicalPath $b.decision.path) -cne $decisionPath -or $b.plan_proposal_sha256 -cnotmatch '^[A-F0-9]{64}$'){throw 'phase_budget_exact_S14_decision_path'}
 Assert-OwnedHash $proposalPath $b.plan_proposal_sha256
 $d=Read-PhaseBudgetProof $b.decision
 if($d.verdict -cne 'ADOPTED_S14_EIGHT_HOUR_R3_VALIDATION' -or $d.scope -cne 'NEW_S14_REMAINING_ORIGINAL_R3' -or $d.strategy -cne 'NEW_S14_FULL_NATIVE_BASELINE_PLUS_FULL_UNCOMPRESSED_PHASE_PEAK_RETAIN_OLD_S13_READONLY' -or !$d.no_additional_compression_authority -or $d.allocated_limit -ne 32GB -or $d.logical_limit -ne 32GB -or $d.metric -cne 'FileStandardInfo.AllocationSize' -or $d.proposal_sha256 -cne $b.plan_proposal_sha256 -or @($d.votes).Count -ne 5 -or (@($d.votes.member_id|Sort-Object)-join ',') -cne 'Customer,PM,QA,Root,TD' -or $d.for_count -lt 3 -or $d.runtime_freeze_utc -cne '2026-10-20T09:54:16Z' -or $d.deadline_utc -cne '2026-10-20T11:24:16Z'){throw 'phase_budget_actual_five_role_S14_decision'}
 $forCount=0
 foreach($v in $d.votes){
  $r=Read-PhaseBudgetProof $v.record
  if($r.author_role -cne $v.member_id -or $r.proposal_sha256 -cne $d.proposal_sha256 -or $r.vote -cne $v.vote -or $r.vote -cnotin @('FOR','AGAINST','ABSTAIN')){throw 'phase_budget_actual_authored_vote'}
  if($r.vote -ceq 'FOR'){
   if($r.allocated_limit -ne 32GB -or $r.logical_limit -ne 32GB -or $r.strategy -cne $d.strategy -or !$r.no_additional_compression_authority){throw 'phase_budget_actual_FOR_resource_binding'}
   $forCount++
  }
 }
 if($forCount -ne $d.for_count -or $forCount -lt 3){throw 'phase_budget_actual_majority'}
 if($Config.runtime_floor_bytes -ne 8GB -or $Config.required_free_bytes -ne 8GB -or $Deadline -gt [DateTimeOffset]::Parse($d.runtime_freeze_utc).UtcDateTime){throw 'phase_budget_S14_floor_and_deadline'}
 foreach($n in @('capture_reservation_bytes','phase_reservation_bytes','phase_allocation_reservation_bytes')){if($Config[$n] -isnot [long] -and $Config[$n] -isnot [int]){throw 'phase_budget_integer_reservation'}}
 if($b.db_wal_temp_extract_archive_bytes -lt 1536MB -or $Config.phase_reservation_bytes -lt ($Config.capture_reservation_bytes+$b.db_wal_temp_extract_archive_bytes) -or $Config.phase_reservation_bytes -gt 8GB -or $Config.phase_allocation_reservation_bytes -lt ($Config.phase_reservation_bytes+128MB)){throw 'phase_budget_full_uncompressed_peak_and_rounding'}
 foreach($role in @('Root','QA','TD')){
  $r=Read-PhaseBudgetProof $b.reviews[$role]
  # Bind actual budget fields, not a circular configSHA->reviewSHA->configSHA.
  if($r.author_role -cne $role -or $r.verdict -cne 'PROSPECTIVE_EXACT_FULL_UNCOMPRESSED_PHASE_RESOURCE_GO' -or $r.scope -cne $Config.scope -or $r.package_sha256.ToUpperInvariant() -cne $Config.package_sha.ToUpperInvariant() -or $r.output_directory -cne $out -or $r.install_parent -cne $install -or $r.capture_reservation_bytes -ne $Config.capture_reservation_bytes -or $r.phase_sha256.ToUpperInvariant() -cne $b.phase_sha.ToUpperInvariant() -or $r.budget_module_sha256.ToUpperInvariant() -cne $b.module_sha.ToUpperInvariant() -or $r.phase_reservation_bytes -ne $Config.phase_reservation_bytes -or $r.phase_allocation_reservation_bytes -ne $Config.phase_allocation_reservation_bytes -or $r.db_wal_temp_extract_archive_bytes -ne $b.db_wal_temp_extract_archive_bytes -or $r.capture_allowlist_sha256 -cne $b.capture_allowlist.sha256 -or !$r.all_other_writers_quiet){throw 'phase_budget_independent_exact_peak_review'}
 }
 $allow=Read-PhaseBudgetProof $b.capture_allowlist
 $captureNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 if($allow.scope -cne $Config.scope -or $allow.phase_sha256 -cne $b.phase_sha -or !$allow.relative_paths -or @($allow.relative_paths).Count -gt 2048){throw 'phase_budget_capture_allowlist_scope'}
 foreach($name in $allow.relative_paths){if($name -cnotmatch '^[a-z][a-z0-9-]{0,63}\.(stdout|stderr|body)$' -or $name -cin @('child.stdout','child.stderr','runner.stdout','runner.stderr') -or !$captureNames.Add($name)){throw 'phase_budget_finite_capture_name'}}
 Import-Module (Join-Path $PSScriptRoot 'evidence-storage.psm1') -Force -DisableNameChecking
 Import-Module (Join-Path $PSScriptRoot 'evidence-meter.psm1') -Force -DisableNameChecking
 if([DateTime]::UtcNow -ge $Deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'phase_budget_before_creation_free_floor'}
 $m=Get-S14EvidenceInventory -DeadlineUtc $Deadline -MaxFiles 160000
 $ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
 foreach($r in $m.files){$ordered.Add($r.path,$r)}
 $path=Join-Path $out 'phase-fresh-native-baseline.jsonl';$s=$null;$sha=[Security.Cryptography.SHA256]::Create();$bytes=0L
 try{$s=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  foreach($r in $ordered.Values){$w=$r.witness;$ci=$w.FileCompressionInfo
   $row=@('s13-native-inventory-v1',$r.path,$r.relative_path,$w.VolumeId,$w.FileId,[string]$w.Links,[string]$w.EndOfFile,[string]$w.AllocationSize,[string]$w.Attributes,$w.FileSystem,[string]$w.FileSystemFlags,$w.FinalPath,[string]$w.CompressionFormat,[string]$ci.CompressedFileSize,[string]$ci.CompressionUnitShift,[string]$ci.ChunkShift,[string]$ci.ClusterShift,[string]$ci.Reserved0,[string]$ci.Reserved1,[string]$ci.Reserved2)
   $raw=[Text.UTF8Encoding]::new($false).GetBytes(($row|ConvertTo-Json -Compress)+"`n");$bytes+=$raw.Length;if($bytes -gt 128MB -or [DateTime]::UtcNow -ge $Deadline){throw 'phase_budget_inventory_capture_limit'}
   [void]$sha.TransformBlock($raw,0,$raw.Length,$raw,0);$s.Write($raw,0,$raw.Length)
  };[void]$sha.TransformFinalBlock([byte[]]::new(0),0,0);$digest=[Convert]::ToHexString($sha.Hash);$s.Flush($true)
 }finally{if($s){$s.Dispose()};$sha.Dispose()}
 $m.Remove('files');$m.inventory_sha256=$digest;$m.inventory_bytes=$bytes;$m.inventory_path=$path
 $fixed=256MB+256MB+256MB
 $logical=[decimal]$m.logical_bytes+$Config.phase_reservation_bytes+$fixed
 $allocated=[decimal]$m.allocated_bytes+$Config.phase_allocation_reservation_bytes+$fixed
 $proof=@{scope=$Config.scope;native_baseline=$m;full_uncompressed_phase_logical=$Config.phase_reservation_bytes;full_uncompressed_phase_allocation=$Config.phase_allocation_reservation_bytes;fixed_reserves=@{metadata=256MB;public=256MB;unmetered_directory_MFT=256MB};logical_upper_bound=$logical;allocated_upper_bound=$allocated;compression_savings_credit=0;not_fresh_active_PG_aggregate=$true;root=$root;out=$out;install=$install;deadline=$Deadline;started=$Started;capture_reservation=$Config.capture_reservation_bytes;install_reservation=$b.db_wal_temp_extract_archive_bytes;capture_files=@($allow.relative_paths);capture_allowlist_sha256=$b.capture_allowlist.sha256;phase_reservation=$Config.phase_reservation_bytes;decision_sha256=$b.decision.sha256;config_sha256=$ConfigSha}
 Write-OwnedJson (Join-Path $out 'phase-fresh-native-baseline-summary.json') $proof
 if($logical -ge 32GB -or $allocated -ge 32GB -or [decimal]([IO.DriveInfo]::new('C').AvailableFreeSpace)-$Config.phase_allocation_reservation_bytes-$fixed -lt 8GB){throw 'phase_budget_fresh_whole_uncompressed_peak_does_not_fit'}
 return $proof
}
function Assert-S14PhaseBudget {
 param([hashtable]$Proof,[long]$Next=0)
 if($Next -lt 0 -or [DateTime]::UtcNow -ge $Proof.deadline -or ([DateTime]::UtcNow-$Proof.started).TotalSeconds -ge 1800 -or [decimal]([IO.DriveInfo]::new('C').AvailableFreeSpace)-$Next -lt 8GB){throw 'phase_budget_next_floor_or_deadline'}
 $phase=Get-PhaseBudgetLogical @($Proof.out,$Proof.install) $Proof
 # Other writers stay quiet throughout this fixture. Charge the complete initial
 # GLOBAL native inventory plus ALL current own output/install bytes and NEXT.
 # Initial own output is deliberately double-counted; never subtract old bytes.
 # Rewalking the entire retained evidence tree before every SQL command is not
 # required to maintain this conservative bound and can exhaust the phase timer.
 $global=[decimal]$Proof.native_baseline.logical_bytes+$phase
 if([DateTime]::UtcNow -ge $Proof.deadline -or ([DateTime]::UtcNow-$Proof.started).TotalSeconds -ge 1800){throw 'phase_budget_scan_deadline'}
 if($phase+$Next -gt $Proof.phase_reservation -or $global+$Next+256MB+256MB+256MB -ge 32GB -or $Proof.allocated_upper_bound -ge 32GB){throw 'phase_budget_actual_logical_or_full_reserved_allocation'}
}
function Get-S14ClosedPhaseBudgetTotals([hashtable]$Proof){
 # Caller must first prove the owned producer/PG/observer are closed. This is a
 # logical final receipt, never a fresh active-PG native allocation measurement.
 $totals=Get-PhaseBudgetLogical @($Proof.out,$Proof.install) $Proof $true
 if($totals.groups.other+4MB -gt 64MB -or $totals.total_bytes+4MB -gt $Proof.phase_reservation -or [decimal]$Proof.native_baseline.logical_bytes+$totals.total_bytes+4MB+768MB -ge 32GB -or $Proof.allocated_upper_bound -ge 32GB -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'closed_phase_budget_or_receipt_headroom'}
 $totals.receipt_reserved_bytes=4MB
 $totals.config_sha256=$Proof.config_sha256
 $totals.decision_sha256=$Proof.decision_sha256
 $totals.scope='CLOSED_PHASE_LOGICAL_INSTALL_CAPTURE_METADATA_TOTALS_NOT_FRESH_NATIVE_ALLOCATION'
 return $totals
}
Export-ModuleMember -Function New-S14PhaseBudget,Assert-S14PhaseBudget,Get-S14ClosedPhaseBudgetTotals
<# SOURCE ONLY. A fresh complete native meter BEFORE package/PG creation is mandatory.
Every failed capture remains charged. Exact whole-phase uncompressed captures, DB,
WAL,temp,extract and archives reserved independently; minimum1536MiB is not a fit
claim. Allocation additionally reserves128MiB rounding; fixed256metadata+256public
+256unmetered directory/MFT charged to both caps. No compressed ratio or IOCTL1GiB
peak reused. All other writers quiet remains an externally reviewed precondition.
While PG active only logical reads plus conservative initial+FULLphase allocation
upper bound; no fresh physical PG aggregate or whole-C-volume claim. Existing known
regression junction not traversed; native initial meter validates its exact identity.
No SQL, process, permission or production5/2/10 modification supplied by this module.
#>


