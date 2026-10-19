param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# FUTURE PROSPECTIVE DRAFT ONLY. CURRENT 16GiB logical cap remains in force.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'compress_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$calibrationSha='F8368FBE5008E657BCE45DF25CDDB8F40D80AA69A9405A9B26D2A9BCC5B01E87'
foreach($p in @(@((Join-Path $PSScriptRoot 'owned-runtime.psm1'),$c.module_sha),@((Join-Path $PSScriptRoot 'evidence-meter.psm1'),$c.meter_sha),@((Join-Path $PSScriptRoot 'evidence-storage.psm1'),$calibrationSha),@($PSCommandPath,$c.phase_sha))){if($p[1] -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $p[0]).Hash -cne $p[1].ToUpperInvariant()){throw 'compress_source_preimport_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-reviewed-closed-sql-stdout-compression' -or $c.allocated_limit -ne 16GB -or $c.logical_limit -ne 40GB -or $c.current_logical_limit -ne 16GB -or $c.maximum_phase_seconds -ne 600){throw 'compress_exact_future_scope'}
$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$root=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../../.local/sprint13')
if(!$out.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'compress_output_must_be_inside_S13'}
function BoundFile([string]$Path){$p=Get-OwnedCanonicalPath $Path;if(!$p.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'compress_s13_only'};Assert-OwnedNoReparse $p;return $p}
function ReadProof($Pin){$p=BoundFile $Pin.path;Assert-OwnedHash $p $Pin.sha256;if((Get-Item -LiteralPath $p).Length -gt 4MB){throw 'compress_proof_cap'};return Get-Content -LiteralPath $p -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
$decision=ReadProof $c.council_decision
$strategy='INITIAL_NO_SAVINGS_CONTROLLED_INTERVAL_V1'
if($decision.verdict -cne 'ADOPTED_S13_DUAL_STORAGE_CAPS' -or $decision.allocated_limit -ne 16GB -or $decision.logical_limit -ne 40GB -or $decision.metric -cne 'FileStandardInfo.AllocationSize' -or @($decision.votes).Count -ne 5 -or @($decision.votes|Where-Object vote -cne 'FOR').Count -or @($decision.votes.member_id|Select-Object -Unique).Count -ne 5){throw 'compress_no_adopted_five_vote_council_decision'}
if((@($decision.votes.member_id|Sort-Object)-join ',') -cne 'Customer,PM,QA,Root,TD' -or $decision.proposal_sha256 -cnotmatch '^[a-fA-F0-9]{64}$'){throw 'compress_exact_five_council_roles'}
foreach($vote in $decision.votes){$record=ReadProof $vote.record;if($record.author_role -cne $vote.member_id -or $record.vote -cne 'FOR' -or $record.proposal_sha256.ToUpperInvariant() -cne $decision.proposal_sha256.ToUpperInvariant()){throw 'compress_actual_authored_vote_record_required'}}
if($decision.guard_strategy -cne $strategy -or $decision.allowed_file_count -ne 8 -or $decision.controlled_allowlist_sha256.ToUpperInvariant() -cne $c.allowlist.sha256.ToUpperInvariant()){throw 'compress_NEW_council_interval_proposal_required'}
foreach($vote in $decision.votes){$record=ReadProof $vote.record;if($record.guard_strategy -cne $strategy){throw 'compress_each_actual_vote_must_authorize_new_interval_strategy'}}
$allow=ReadProof $c.allowlist;$registry=ReadProof $c.sql_registry
if($allow.scope -cne $c.scope -or @($allow.files).Count -ne 8 -or $registry.scope -cne 'S13_EXACT_REVIEWED_READONLY_CAPTURE_SQL_REGISTRY'){throw 'compress_allowlist_registry_scope'}
foreach($entry in @(@{role='QA';pin=$c.qa_review},@{role='TD';pin=$c.td_review})){
 $r=ReadProof $entry.pin
 if($r.author_role -cne $entry.role -or $r.verdict -cne 'PROSPECTIVE_EXACT_CLOSED_SQL_FILE_COMPRESSION_GO' -or $r.allowlist_sha256.ToUpperInvariant() -cne $c.allowlist.sha256.ToUpperInvariant() -or $r.council_decision_sha256.ToUpperInvariant() -cne $c.council_decision.sha256.ToUpperInvariant() -or $r.registry_sha256.ToUpperInvariant() -cne $c.sql_registry.sha256.ToUpperInvariant() -or $r.phase_sha256.ToUpperInvariant() -cne $c.phase_sha.ToUpperInvariant() -or $r.meter_sha256.ToUpperInvariant() -cne $c.meter_sha.ToUpperInvariant() -or $r.calibration_sha256.ToUpperInvariant() -cne $calibrationSha){throw 'compress_independent_exact_review_required'}
}
$calibration=ReadProof $c.actual_calibration_review
if($calibration.verdict -cne 'ACTUAL_STORAGE02_THREE_CYCLES_NATIVE0_SHA_ACL_FILEID_REVIEWED' -or $calibration.module_sha256.ToUpperInvariant() -cne $calibrationSha){throw 'compress_actual_benign_calibration_review_required'}
foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256}
$freeze=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime;$end=[DateTime]::UtcNow.AddSeconds(600);if($freeze -lt $end){$end=$freeze}
if($freeze -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or [DateTime]::UtcNow -ge $end){throw 'compress_runtime_freeze'}
if($c.reserved_logical_bytes -ne 160MB -or $c.reserved_allocated_bytes -ne 160MB){throw 'compress_inventory_and_receipt_headroom_required'}
if($c.public_supplement_logical_bytes -ne 256MB -or $c.public_supplement_allocated_bytes -ne 256MB){throw 'compress_explicit_public_repo_git_supplement'}
if($c.filesystem_overhead_reserved_bytes -ne 256MB -or $c.next_uncompressed_reserved_bytes -ne 1GB){throw 'compress_fixed_unmetered_MFT_and_NEXT_peak_reserves'}
$quiet=ReadProof $c.quiet_review
if($quiet.author_role -cne 'Root' -or $quiet.verdict -cne 'S13_EXCLUSIVE_CONTROLLED_COMPRESSION_INTERVAL_GO' -or $quiet.guard_strategy -cne $strategy -or $quiet.owned_output_directory -cne $out -or $quiet.allowlist_sha256.ToUpperInvariant() -cne $c.allowlist.sha256.ToUpperInvariant() -or $quiet.phase_sha256.ToUpperInvariant() -cne $c.phase_sha.ToUpperInvariant() -or !$quiet.no_other_managed_writers -or !$quiet.pg_compilers_closed){throw 'compress_independent_entire_interval_writer_freeze_required'}
Import-Module (Join-Path $PSScriptRoot 'evidence-storage.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'evidence-meter.psm1') -Force -DisableNameChecking
$storage=Get-Module|Where-Object Path -ceq (Join-Path $PSScriptRoot 'evidence-storage.psm1')
if(@($storage).Count -ne 1){throw 'compress_exact_storage_module_instance'}
$initialRows=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
$initialIdentities=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$allowedTargets=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$completedTargets=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($t in $allow.files){$p=BoundFile $t.path;if($p.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)-or !$allowedTargets.Add($p)){throw 'compress_eight_unique_targets_outside_owned_metadata_required'}}
$baseline=@{junctions=$null}
function CanonicalRow($r){$w=$r.witness;$ci=$w.FileCompressionInfo;return (@('s13-native-inventory-v1',$r.path,$r.relative_path,$w.VolumeId,$w.FileId,[string]$w.Links,[string]$w.EndOfFile,[string]$w.AllocationSize,[string]$w.Attributes,$w.FileSystem,[string]$w.FileSystemFlags,$w.FinalPath,[string]$w.CompressionFormat,[string]$ci.CompressedFileSize,[string]$ci.CompressionUnitShift,[string]$ci.ChunkShift,[string]$ci.ClusterShift,[string]$ci.Reserved0,[string]$ci.Reserved1,[string]$ci.Reserved2)|ConvertTo-Json -Compress)}
function HeldHash([IO.FileStream]$s){if([DateTime]::UtcNow -ge $end){throw 'compress_hash_deadline'};return & $storage {param($s) Get-S13CalibrationHash $s} $s}
function HeldAcl([IO.FileStream]$s){
 $acl=[IO.FileSystemAclExtensions]::GetAccessControl($s);$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 # Capture files inherit their sole SID ACL from a protected private output dir;
 # do not mutate ACL or silently require a protected file ACE after creation.
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'compress_current_sid_only_acl'}
 return $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group)
}
function SaveMeter([string]$Label,[bool]$Full=$false){
 if(!$Full -or $Label -cnotin @('initial-all-files','final-all-files')){throw 'compress_only_two_full_meter_calls'}
 $m=Get-S13EvidenceInventory -DeadlineUtc $end
 $p=Join-Path $out ($Label+'.jsonl');$s=$null;$n=0L;$hash=[Security.Cryptography.SHA256]::Create();$ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
 foreach($r in $m.files){$ordered.Add($r.path,$r)}
 $junctionJson=ConvertTo-Json -InputObject @($m.junctions) -Depth 20 -Compress
 if($Label -ceq 'initial-all-files'){$baseline.junctions=$junctionJson}else{if($junctionJson -cne $baseline.junctions){throw 'compress_final_junction_changed'};foreach($oldPath in $initialRows.Keys){if(!$ordered.ContainsKey($oldPath)){throw 'compress_final_missing_initial_file'}}}
 try{
  if($Full){$s=[IO.File]::Open($p,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}
  foreach($r in $ordered.Values){
   $w=$r.witness;$ci=$w.FileCompressionInfo;$canonical=CanonicalRow $r
   if($Label -ceq 'initial-all-files'){$initialRows.Add($r.path,$canonical);$initialIdentities.Add($r.path,$r)}
   elseif(!$r.path.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
    if(!$initialRows.ContainsKey($r.path)){throw 'compress_final_new_outside_owned_output'}
    if($allowedTargets.Contains($r.path)){
     if(!$completedTargets.ContainsKey($r.path) -or $canonical -cne $completedTargets[$r.path].canonical){throw 'compress_final_target_not_exact_completed_witness'}
    }elseif($canonical -cne $initialRows[$r.path]){throw 'compress_final_unrelated_native_metadata_changed'}
   }
   # Fixed-schema ordinal-path sorted canonical rows; every native record enters
   # the SHA even when a per-step physical inventory copy is deliberately absent.
   $row=@('s13-native-inventory-v1',$r.path,$r.relative_path,$w.VolumeId,$w.FileId,[string]$w.Links,[string]$w.EndOfFile,[string]$w.AllocationSize,[string]$w.Attributes,$w.FileSystem,[string]$w.FileSystemFlags,$w.FinalPath,[string]$w.CompressionFormat,[string]$ci.CompressedFileSize,[string]$ci.CompressionUnitShift,[string]$ci.ChunkShift,[string]$ci.ClusterShift,[string]$ci.Reserved0,[string]$ci.Reserved1,[string]$ci.Reserved2)
   $b=[Text.UTF8Encoding]::new($false).GetBytes(($row|ConvertTo-Json -Compress)+"`n");$n+=$b.Length;if($n -gt 64MB){throw 'compress_meter_inventory_receipt_cap'};[void]$hash.TransformBlock($b,0,$b.Length,$b,0);if($s){$s.Write($b,0,$b.Length)}
  }
  [void]$hash.TransformFinalBlock([byte[]]::new(0),0,0);$digest=[Convert]::ToHexString($hash.Hash);if($s){$s.Flush($true)}
 }finally{if($s){$s.Dispose()};$hash.Dispose()}
 $m.Remove('files');$m.inventory_path=if($Full){$p}else{$null};$m.inventory_sha256=$digest;$m.inventory_bytes=$n;$m.full_inventory_file_retained=$Full;$m.inventory_schema='s13-native-inventory-v1 fixed20field stringarray rows sorted fullpath Ordinal, UTF8 LF';$m.all_native_records_processed=$true
 if($Label -ceq 'final-all-files'){$m.namespace_comparison=@{initial_file_count=$initialRows.Count;final_file_count=$ordered.Count;missing_initial_files=0;new_outside_output_files=0;unrelated_metadata_changes=0;exact_completed_targets=$completedTargets.Count;junctions_exact_unchanged=$true;allowed_output_subtree=$out;field_scope='Canonical20: path/relative_path/volume/fileID/links/EOF/allocation/attributes/filesystem/flags/finalpath/allCompressionInfo fields; no whole-volume or content-hash claim for unrelated files'}}
 Write-OwnedJson (Join-Path $out ($Label+'-summary.json')) $m
 return $m
}
function MetadataGuard{
 $logical=0L;$allocated=0L;$count=0;$stack=[Collections.Generic.Stack[string]]::new();$stack.Push($out)
 while($stack.Count){$dir=$stack.Pop();Assert-OwnedNoReparse $dir;foreach($f in Get-ChildItem -LiteralPath $dir -Force){
  if([DateTime]::UtcNow -ge $end -or ++$count -gt 100000){throw 'compress_metadata_deadline_or_count'}
  Assert-OwnedNoReparse $f.FullName;if($f.PSIsContainer){$stack.Push($f.FullName);continue}
  Assert-OwnedNoReparse $f.FullName;$h=$null;$s=$null
  try{$h=[PiS13AttributesHandle]::Open($f.FullName);$s=[IO.FileStream]::new($h,[IO.FileAccess]::Read,1,$false);$w=[PiS13EvidenceStorageV1]::Inspect($s);$logical+=$w.EndOfFile;$allocated+=$w.AllocationSize}finally{if($s){$s.Dispose()}elseif($h){$h.Dispose()}}
 }}
 if($logical -gt 160MB -or $allocated -gt 160MB){throw 'compress_owned_metadata_reservation_exceeded'}
 return @{logical_bytes=$logical;allocated_bytes=$allocated}
}
function Peak($Meter,$Target){
 if([DateTime]::UtcNow -ge $end){throw 'compress_phase_deadline'}
 $running=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {($_.Name -in @('cargo.exe','rustc.exe','rustdoc.exe','link.exe','clang.exe','gcc.exe')) -or ($_.Name -ceq 'postgres.exe' -and (!$_.ExecutablePath -or $_.ExecutablePath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)))})
 if($running.Count){throw 'compress_interval_requires_closed_s13_pg_and_compilers'}
 foreach($v in @($c.reserved_logical_bytes,$c.reserved_allocated_bytes,$Target.next_uncompressed_logical_bytes,$Target.next_uncompressed_allocated_bytes)){if($v -isnot [long] -and $v -isnot [int]){throw 'compress_integer_reservation'};if($v -lt 0){throw 'compress_negative_reservation'}}
 if($Target.next_uncompressed_logical_bytes -ne 1GB -or $Target.next_uncompressed_allocated_bytes -ne 1GB){throw 'compress_exact_one_GiB_NEXT_reservation'}
 $logical=[decimal]$Meter.logical_bytes+256MB+160MB+256MB+1GB
 $allocated=[decimal]$Meter.allocated_bytes+256MB+160MB+256MB+1GB
 if($logical -ge 40GB -or $allocated -ge 16GB -or [decimal]([IO.DriveInfo]::new('C').AvailableFreeSpace)-256MB-160MB-256MB-1GB -lt 4GB){throw 'compress_initial_no_savings_upper_bound_or_floor'}
 $metadata=MetadataGuard
 return @{strategy=$strategy;baseline_inventory_sha256=$Meter.inventory_sha256;baseline_logical_bytes=$Meter.logical_bytes;baseline_allocated_bytes=$Meter.allocated_bytes;upper_bound_logical_bytes=$logical;upper_bound_allocated_bytes=$allocated;compression_credit_bytes=0;fresh_per_step_aggregate=$false;metadata=$metadata;unmetered_directory_MFT_reserved_bytes=256MB;public_supplement_bytes=256MB;metadata_reserved_bytes=160MB;next_uncompressed_reserved_bytes=1GB}
}
$initialInventory=SaveMeter 'initial-all-files' $true
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$number=0
foreach($target in $allow.files){
 if([DateTime]::UtcNow -ge $end){throw 'compress_phase_deadline'}
 if(![IO.Path]::IsPathFullyQualified($target.path)){throw 'compress_absolute_allowlisted_target'}
 $file=BoundFile $target.path
 if(!$file.EndsWith('.stdout',[StringComparison]::Ordinal) -or !$seen.Add($file) -or $file -match '(?i)[\\/](pgdata|runtime|src|target01|compile03-artifacts|release-source01)[\\/]'){throw 'compress_target_file_kind'}
 Assert-OwnedPrivateDirectory (Split-Path -Parent $file)
 $producer=ReadProof $target.producer_record;$invocation=ReadProof $target.producer_invocation
 if($invocation.basis -cne 'DETERMINISTIC_PINNED_PHASE_SOURCE_AND_CONFIG_NOT_SEPARATE_CIM_ARGV' -or $invocation.producer_label -cne [IO.Path]::GetFileNameWithoutExtension($file)){throw 'compress_honest_invocation_source_basis'}
 foreach($pin in @($invocation.phase_source,$invocation.phase_config,$invocation.helper)){Assert-OwnedHash $pin.path $pin.sha256}
 if($invocation.phase_config.sha256.ToUpperInvariant() -cne $invocation.runtime_sha256.ToUpperInvariant() -or (Get-OwnedCanonicalPath $invocation.helper.path) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'owned-runtime.psm1')) -or $invocation.helper.sha256.ToUpperInvariant() -cne $c.module_sha.ToUpperInvariant()){throw 'compress_invocation_actual_phase_config_helper_pins'}
 if($producer.pid -le 0 -or $producer.native_exit -ne 0 -or !$producer.stdout_complete -or !$producer.stderr_complete -or $producer.capture_fault -or $producer.output_limit -or $producer.drain_timeout -or $producer.stdout_bytes_persisted -ne $target.bytes -or $producer.stdout_sha256.ToUpperInvariant() -cne $target.sha256.ToUpperInvariant() -or [IO.Path]::GetFileName($producer.program) -cne 'psql.exe' -or $producer.program_sha256.ToUpperInvariant() -cne $target.psql_sha256.ToUpperInvariant()){throw 'compress_not_closed_successful_psql_producer'}
 if(!$target.producer_record.path.EndsWith('.process.json',[StringComparison]::Ordinal) -or (Get-OwnedCanonicalPath ($target.producer_record.path.Substring(0,$target.producer_record.path.Length-13)+'.stdout')) -cne $file){throw 'compress_native_record_stdout_name_binding'}
 Assert-OwnedHash (BoundFile $producer.program) $producer.program_sha256
 $start=[DateTimeOffset]::Parse($producer.native_creation_utc).UtcDateTime;$completed=[DateTimeOffset]::Parse($producer.completed_utc).UtcDateTime;$spawned=[DateTimeOffset]::Parse($producer.started_utc).UtcDateTime
 if($start -lt [DateTimeOffset]::Parse('2026-10-19T13:14:42Z').UtcDateTime -or $spawned -lt [DateTimeOffset]::Parse('2026-10-19T13:14:42Z').UtcDateTime -or $start -lt $spawned.AddSeconds(-1) -or $completed -lt $start -or $completed -gt [DateTime]::UtcNow){throw 'compress_not_new_s13_producer'}
 $live=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$producer.pid)
 if($live -and [Math]::Abs(($live.CreationDate.ToUniversalTime()-$start).TotalSeconds) -lt 1){throw 'compress_original_producer_still_alive'}
 if($invocation.stdout_path -cne $file -or $invocation.native_record_sha256.ToUpperInvariant() -cne $target.producer_record.sha256.ToUpperInvariant() -or $invocation.program -cne $producer.program -or $invocation.program_sha256.ToUpperInvariant() -cne $producer.program_sha256.ToUpperInvariant() -or $invocation.database -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$' -or $invocation.port -ne 5465 -or $invocation.sql_path -cne $target.sql.path -or $invocation.sql_sha256.ToUpperInvariant() -cne $target.sql.sha256.ToUpperInvariant()){throw 'compress_producer_sql_invocation_binding'}
 # Exact READ-ONLY SQL source exceptions; never compression destinations.
 $workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..')
 $managedSql=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')
 $oldCaptureSql=Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint11/root/sql5-inputs01/capture.sql')
 $sql=Get-OwnedCanonicalPath $target.sql.path
 if($sql -ceq $managedSql){Assert-OwnedHash $sql '65611973FCDF6D6C172BF22EB9B2A9CC19A0F21615634BBDEFD4F2732E87AEB0'}
 elseif($sql -ceq $oldCaptureSql){Assert-OwnedHash $sql '054242566AC35D3AFAC986298BB030D8536A72710FA40F30ECA3193D8361A45B'}
 else{[void](BoundFile $sql)}
 Assert-OwnedNoReparse $sql;Assert-OwnedHash $sql $target.sql.sha256
 $matches=@($registry.queries|Where-Object { $_.path -ceq $sql -and $_.sha256.ToUpperInvariant() -ceq $target.sql.sha256.ToUpperInvariant() -and $_.read_only -eq $true })
 $expectedArgs=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5465','-U',$invocation.user,'-w','-d',$invocation.database,'-f',$sql)
 if($target.argv_profile -ceq 'ACTUAL_HISTORICAL03_14_NO_X'){
  $admissionPath=Join-Path $root 'root/historical-migration03/root-admission01.json'
  if((Get-OwnedCanonicalPath $c.historical03_admission.path) -cne (Get-OwnedCanonicalPath $admissionPath)){throw 'compress_literal_historical03_admission'}
  $oldAdmission=ReadProof $c.historical03_admission
  $historicalPsql=Join-Path $root 'root/historical-install03/process-intelligence-rs-0.7.3-windows-x86_64/runtime/postgresql/pgsql/bin/psql.exe'
  if($oldAdmission.role -cne 'Root' -or $oldAdmission.runtime_sha -cne '1E72579322C75E5D3FB0E3899BF22BFFA844F4D809CB11C5E8407A39AAA447C3' -or $invocation.runtime_sha256 -cne $oldAdmission.runtime_sha -or !$oldAdmission.psqlrc_override_absent -or !$oldAdmission.user_psql_startup_files_absent -or $producer.program -cne $historicalPsql -or $sql -cne $managedSql -or !$file.StartsWith((Join-Path $root 'root/historical-migration03/'),[StringComparison]::OrdinalIgnoreCase) -or $producer.program_sha256 -cne 'FDE952534F520909C02DB04675588ECB1DA8D618B6E5C93E106F42A752DAF720'){throw 'compress_narrow_historical03_no_x_exception'}
  $expectedArgs=@('-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-d',$invocation.database,'-qAt','-v','ON_ERROR_STOP=1','-f',$sql)
 }elseif($target.argv_profile -cne 'PREFERRED17_WITH_X'){throw 'compress_explicit_argv_profile'}
 if($matches.Count -ne 1 -or $invocation.user -cnotin @('pi_admin','pi_app') -or $invocation.arguments -isnot [array] -or $invocation.arguments.Count -ne $expectedArgs.Count){throw 'compress_exact_readonly_sql_registry_required'}
 for($ai=0;$ai -lt $expectedArgs.Count;$ai++){if($invocation.arguments[$ai] -isnot [string] -or $invocation.arguments[$ai] -cne $expectedArgs[$ai]){throw 'compress_exact_psql_argv_required'}}
 if($target.bytes -lt 1 -or $target.bytes -gt 1GB -or $target.next_uncompressed_logical_bytes -lt $target.bytes -or $target.next_uncompressed_allocated_bytes -lt $target.next_uncompressed_logical_bytes){throw 'compress_target_or_uncompressed_reservation'}
 $number++;$label='compress-'+$number;$beforeBound=Peak $initialInventory $target
 $stream=$null;$read=$null;$api=$null;$before=$null;$after=$null;$done=$false
 try{
  $stream=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,65536,[IO.FileOptions]::SequentialScan)
  $before=[PiS13EvidenceStorageV1]::Inspect($stream);$hash=HeldHash $stream;$acl=HeldAcl $stream
  if(!$initialIdentities.ContainsKey($file)){throw 'compress_target_missing_initial_inventory'}
  $initial=$initialIdentities[$file];$observed=@{path=$file;relative_path=$initial.relative_path;witness=$before}
  if((CanonicalRow $observed) -cne $initialRows[$file]){throw 'compress_target_changed_since_initial_inventory'}
  $expected=([PiResolvedPath]::Get((Split-Path -Parent $file))).TrimEnd('\')+'\'+[IO.Path]::GetFileName($file)
  if($before.Links -ne 1 -or $before.FileSystem -cne 'NTFS' -or ($before.Attributes -band 0x445650) -or $before.CompressionFormat -ne 0 -or $before.EndOfFile -ne $target.bytes -or $hash -cne $target.sha256.ToUpperInvariant() -or !$before.FinalPath.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'compress_exclusive_fresh_source_guard'}
  $api=[PiS13EvidenceStorageV1]::Set($stream,[ushort]1)
  Write-OwnedJson (Join-Path $out ($label+'-api.json')) @{api=$api;before=$before;sha256=$hash;acl=$acl;exact_path=$file;original_producer_gone_checked_utc=[DateTime]::UtcNow.ToString('o');no_retry=$true}
  if(!$api.ApiReturnedTrue -or $api.Win32Error -ne 0){throw 'compress_api_refused_retained'}
  $stream.Flush($true);$after=[PiS13EvidenceStorageV1]::Inspect($stream);$afterHash=HeldHash $stream;$afterAcl=HeldAcl $stream
  & $storage {param($b,$a,$h,$ah,$acl,$aacl) Assert-S13CalibrationStable $b $a $h $ah $acl $aacl} $before $after $hash $afterHash $acl $afterAcl
  if($after.CompressionFormat -ne 2 -or $after.AllocationSize -ge $before.AllocationSize){throw 'compress_actual_allocation_reduction_guard'}
  $stream.Dispose();$stream=$null
  $read=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,65536,[IO.FileOptions]::SequentialScan)
  $final=[PiS13EvidenceStorageV1]::Inspect($read);$finalHash=HeldHash $read;$finalAcl=HeldAcl $read
  & $storage {param($b,$a,$h,$ah,$acl,$aacl) Assert-S13CalibrationStable $b $a $h $ah $acl $aacl} $before $final $hash $finalHash $acl $finalAcl
  if($final.AllocationSize -ne $after.AllocationSize -or $final.CompressionFormat -ne 2){throw 'compress_readonly_reopen_guard'}
  $read.Dispose();$read=$null
  $completedTargets.Add($file,@{canonical=(CanonicalRow @{path=$file;relative_path=$initial.relative_path;witness=$final});sha256=$finalHash;acl=$finalAcl;witness=$final})
  $postBound=Peak $initialInventory $target
  Write-OwnedJson (Join-Path $out ($label+'-receipt.json')) @{status='CLOSED_SQL_STDOUT_COMPRESSION_EVIDENCE_PENDING_QA_TD';path=$file;sha256=$finalHash;logical_bytes=$final.EndOfFile;before=$before;after=$after;readonly_reopen=$final;api=$api;acl_unchanged=$true;conservative_pre=$beforeBound;conservative_post=$postBound;producer_record_sha256=$target.producer_record.sha256;council_decision_sha256=$c.council_decision.sha256;allocation_metric='FileStandardInfo.AllocationSize';automatic_retry=$false;whole_sprint_acceptance=$false}
  $done=$true
 }finally{
  if($stream){$stream.Dispose()};if($read){$read.Dispose()}
  if(!$done){Write-OwnedJson (Join-Path $out ($label+'-partial-or-failed.json')) @{status='FAILED_RETAINED_DO_NOT_RETRY';path=$file;api=$api;api_succeeded_but_later_guard_may_have_failed=($null -ne $api -and $api.ApiReturnedTrue);before=$before;after=$after;no_rollback_or_decompression=$true;no_success_receipt=$true}}
 }
}
$finalInventory=SaveMeter 'final-all-files' $true;$finalBound=Peak $initialInventory $allow.files[-1]
if($finalInventory.logical_bytes -gt $finalBound.upper_bound_logical_bytes -or $finalInventory.allocated_bytes -gt $finalBound.upper_bound_allocated_bytes -or $completedTargets.Count -ne 8){throw 'compress_final_actual_exceeds_conservative_bound'}
foreach($file in $completedTargets.Keys){$s=$null;try{$s=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$w=[PiS13EvidenceStorageV1]::Inspect($s);$r=@{path=$file;relative_path=$initialIdentities[$file].relative_path;witness=$w};if((CanonicalRow $r) -cne $completedTargets[$file].canonical -or (HeldHash $s) -cne $completedTargets[$file].sha256 -or (HeldAcl $s) -cne $completedTargets[$file].acl){throw 'compress_final_target_whole_hash_identity_acl'}}finally{if($s){$s.Dispose()}}}
foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256};Assert-OwnedHash $PhaseConfig $PhaseConfigSha
Write-OwnedJson (Join-Path $out 'evidence-compress-result.json') @{status='FINITE_CLOSED_SQL_COMPRESSION_EVIDENCE_PENDING_QA_TD';files=$number;guard_strategy=$strategy;initial_inventory=$initialInventory;final_inventory=$finalInventory;conservative_final_bound=$finalBound;no_budget_acceptance=$true;limits=@('Current16GiB logical cap remains authoritative until NEW actual adopted five-vote interval amendment','Exactly eight reviewed successful closed newS13 psql stdout files','Initial and final native aggregates only; no fresh per-step aggregate','Initial allocation never reduced by compression savings; fixed160MiB metadata+256MiB public+256MiB unmetered directory/MFT+1GiB NEXT reserves','External Root writer freeze required throughout; final namespace comparison is not a continuous writer attribution proof','No old/active/PG/source/binary/CLI/truncated file touched','No FileCopy/deletion/decompression/retry','Native outer host exit/fullEOF/Job proof remains independent','Native meter scope is S13 file allocation plus exact fixture junction, not whole-volume allocation')}
[void](MetadataGuard)

<#
SOURCE-ONLY PROPOSAL, NOT EXECUTED/ADOPTED. This code grants NO runtime permission.
Root/QA/TD fullread+actual benign calibration+five adopted Council votes required
BEFORE any real compression. CURRENT cap16GiBlogical stays in force meanwhile.
Future config exactscope,phase/module/meter hashes,pinned F836 calibrationmodule,
council_decision/allowlist/sql_registry/qa_review/td_review/actual_calibration_review
each{path,sha256},pins[],privateoutput_directory,deadline<=runtimefreeze,max600s,
allocated_limit16GiB,logical_limit40GiB,current_logical_limit16GiB,reservedlogical/
allocated EXACT160MiB (two64MiB inventories plus all own receipts/temp/headroom).
Independently reviewed allowlist EXACT8 files includes path,
bytes/SHA,producerrecord/invocation{path,sha},psqlSHA,sql{path,sha},NEXT UNCOMPRESSED
logical/allocated reservations. Producer0/fullEOF/no fault/cap/drain checked even
if a LATER surrounding phase failed. Freshwholehash+originalproducerPIDcreation
gone checked. Registry binds exact read-only SQL bytes; flags alone are NOT SQL
purity proof and require independent source review. All evidence privateCreateNew.
Exact SQLsource readonly exceptions: tools/sprint13/managed-state.sql656119...AEB0
and originalSprint11capture.sql054242...1A45B; neither can be compressiontarget.
PREFERRED17_WITH_X actualargv required normally; ACTUAL_HISTORICAL03_14_NO_X
exception ONLY for actualhistorical03 directory/immutablepackagepsqlFDE952,
Rootadmission01(runtime1E725,psqlrc_override_absent/userstartupabsent), invocations
bound same runtime hash, managedSQL only, actual14ordered args (never invent-X).
Public source/Git delta is NOT native-metered: separate256MiB logical+allocated
supplement reserve added to BOTH peak inequalities and globalfreefloor; no whole
Cdrive allocation claim. Node/proofwriters must be quiet for complete meterpasses;
all S13 PG and compilers closed (read-only CIMrefusal, no process stopped here).
Meter metadata uses attributes-only shared native handles, fullfixedS13 noexclude,
100kfiles/two passes/120s/max40GiBlogical. READONLYmeter accepts links>=1, charges
EVERYpathname fullnativeAllocationSize/logicalbytes (aliases deliberately overcount),
reports duplicateIDs/nativeLinks/cross-boundary aliases; compressor STILL links1.
Only initial/final fullnative inventory passes and fullcanonical files. EACHstep
uses the INITIAL native totals WITHOUT EVER subtracting compression savings:
initial +160MiB ownmetadata +256MiB public +256MiB UNMETERED ordinarydirectory/MFT
overhead +1GiB NEXT uncompressed IOCTL peak. Both logical/allocated inequalities
are conservative; global4GiB freefloor and600s freeze checked every step. Actual
own-output logical AND native allocated bytes <=160MiB, including inventories,
receipts/temp. Native source allocation must strictly decrease independently.
NO fresh per-step aggregate is claimed. Entire controlled interval requires Root
attestation of no other S13 writers, closed PG/compiler processes, exact8targets
and ownoutput only. Final native namespace compares ALL initial entries: none
missing, no outside-output new files, only exact targets/output may differ. All
unrelated Canonical20 native fields and knownjunction metadata remain identical;
all8 targets final allbyteSHA/ACL/identity checked. This end comparison cannot
attribute writers or detect a transient mutation fully reverted between checks;
independent external freeze remains essential, not simulated by an assertion.
New decision and EACH authored vote must bind INITIAL_NO_SAVINGS_CONTROLLED_INTERVAL_V1
and exactallowlist; earlier unexecuted strategies grant no permission. Later PG
work needs a separate fresh actualmeter/wholepeak admission, never savings credit.
Council EXACT Root/QA/TD/PM/Customer FOR records individually SHAread and author/
proposalbound; decision/review alone cannot substitute actual authored votes.
Invocation basis is deterministic pinnedphase/config/helper source, NOT separate
CIMargv capture. Root/QA/TD must review exact producerlabel mapping and callsource.
Reparse/races/inaccessibleSTOP; no native or cap acceptance asserted by this draft.
Each IOCTL is sameexclusiveReadWritehandle with allbytehash/ACL/identity/length;
actualBOOL/rawerror recorded immediately, knownpartial success retained if later
guardfails. If host dies insideIOCTL/receiptwrite, outcome is UNCONFIRMED and no
automatic retry is authorized; absence of APIrecord is not evidence no mutation.
Readonly reopen rehash proves bytepreservation. No cap/ratio/diskdelta
fallback, no data rewrite, no evidence deletion and no actual acceptance claims.
#>
