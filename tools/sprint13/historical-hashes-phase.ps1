param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# UNEXECUTED DRAFT. Pure Rust replay only; no PostgreSQL, HTTP, migration or build.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'historical_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$module=Join-Path $PSScriptRoot 'owned-runtime.psm1'
$source=Join-Path $workspace 'examples/sprint13_legacy_hashes.rs'
$inventory=Join-Path $workspace '.local/sprint13/root/compile03-artifacts/inventory.json'
$program=Join-Path $workspace '.local/sprint13/root/compile03-artifacts/sprint13_legacy_hashes.exe'
$input=Join-Path $workspace '.local/sprint09/qa/old03-full-values01.jsonl'
$inputSha='79AE70BEC3E552C38B79C1B28E05AA1C4C785B4AE3B0475F70BEC1281CE0256D'
$programSha='E715AD86BDF64488A0DFBE0A3689625A67E40DA1A97EBFD462EDEA2B24E2D4C6'
$sourceSha='747C120BD17F7EFC7FF6CECEBF64D71D7AFAD153964EEA847184D71042271781'
$inventorySha='B5EDB55DF45A004EDE1A8D82BE9EB78DAACB3E72F787F4C90BF1750BEAA3A89C'
# All executable/imported source pins checked BEFORE importing any helper.
foreach($pin in @(@($module,$c.module_sha),@($PSCommandPath,$c.phase_sha),@($source,$sourceSha),@($inventory,$inventorySha),@($program,$programSha))){
 if($pin[1] -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $pin[0]).Hash -cne $pin[1].ToUpperInvariant()){throw 'historical_preimport_source_pin'}
}
Import-Module $module -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-pure-rust-historical-value-hashes' -or $c.maximum_phase_seconds -ne 180 -or $c.maximum_output_bytes -ne 1MB -or $c.input_bytes -ne 307160864 -or $c.input_sha256.ToUpperInvariant() -cne $inputSha -or $c.program_sha256.ToUpperInvariant() -cne $programSha){throw 'historical_exact_scope'}
foreach($pair in @(@($c.input,$input),@($c.program,$program),@($c.source,$source),@($c.inventory,$inventory))){if((Get-OwnedCanonicalPath $pair[0]) -cne (Get-OwnedCanonicalPath $pair[1])){throw 'historical_literal_inputs'}}
foreach($p in @($input,$program,$source,$inventory)){Assert-OwnedNoReparse $p}
if((Get-Item -LiteralPath $inventory).Length -gt 1MB -or (Get-Item -LiteralPath $source).Length -gt 1MB -or (Get-Item -LiteralPath $program).Length -ne 59231232){throw 'historical_artifact_bounds'}
$inv=Get-Content -LiteralPath $inventory -Raw|ConvertFrom-Json -DateKind String
if($inv.config_sha256 -cne '0E35CB26AB3CFD498800E8FFD57C133CC5EB71CD1422DD40C5AECCEB2331F654'){throw 'historical_compile03_binding'}
$artifact=@($inv.artifacts|Where-Object Name -ceq 'sprint13_legacy_hashes')
if($artifact.Count -ne 1 -or $artifact[0].path -cne $program -or $artifact[0].sha256 -cne $programSha -or $artifact[0].bytes -ne 59231232 -or @($artifact[0].kind).Count -ne 1 -or $artifact[0].kind[0] -cne 'example'){throw 'historical_actual_inventory_binding'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$freeze=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($freeze -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or [DateTime]::UtcNow -ge $freeze -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB){throw 'historical_freeze_or_capacity'}
$end=[DateTime]::UtcNow.AddSeconds(180);if($freeze -lt $end){$end=$freeze}
$held=$null;$child=$null;$native=$null;$complete=$false;$forced=$false
function HashHeld([IO.FileStream]$Stream){
 if([DateTime]::UtcNow -ge $end){throw 'historical_hash_deadline'}
 $Stream.Position=0;$sha=[Security.Cryptography.SHA256]::Create()
 try{return [Convert]::ToHexString($sha.ComputeHash($Stream))}finally{$sha.Dispose()}
}
try{
 # Read-only SHARE_READ holds this ORIGINAL input against write/delete for the
 # entire child execution. Rust opens it independently for read; no private copy,
 # no content logging and no 307MB PowerShell JSON materialization.
 $held=[IO.FileStream]::new($input,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,65536,[IO.FileOptions]::SequentialScan)
 if($held.Length -ne 307160864){throw 'historical_actual_whole_input_length'}
 $pre=HashHeld $held
 if($pre -cne $inputSha){throw 'historical_actual_whole_input_hash'}
 Write-OwnedJson (Join-Path $out 'historical-input-pre.json') @{path=$input;bytes=$held.Length;sha256=$pre;full_byte_read=$true;read_only_guard_held_through_child=$true;source_sha256=$sourceSha;program_sha256=$programSha;inventory_sha256=$inventorySha;scope='Current whole-file supervision, independent of executable hardcoded input_sha256 claim'}
 if([DateTime]::UtcNow -ge $end){throw 'historical_prelaunch_deadline'}
 # Named typed array and named parameter prevent literal/positional argument loss.
 [string[]]$arguments=@($input)
 $child=Start-OwnedCapturedProcess -Program $program -ProgramSha256 $programSha -Arguments $arguments -WorkingDirectory $out -OutputDirectory $out -Label 'historical-rust' -MaxOutputBytes 1MB -Environment @{}
 while(!$child.Process.WaitForExit(100)){
  if([DateTime]::UtcNow -ge $end -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){$forced=$true;$child.Process.Kill($true);if(!$child.Process.WaitForExit(10000)){throw 'historical_owned_child_stop_deadline'};break}
 }
 $native=Complete-OwnedCapturedProcess $child
 Write-OwnedJson (Join-Path $out 'historical-native.json') @{native=$native;forced=$forced;argument_count=1;input_argument_path=$input;explicit_environment_names=@();no_retry=$true}
 # Post-hash even after native refusal where possible. Failure remains failed,
 # never converted to success merely because input stayed unchanged.
 $post=HashHeld $held
 if($held.Length -ne 307160864 -or $post -cne $inputSha -or $post -cne $pre){throw 'historical_whole_input_changed'}
 Assert-OwnedHash $source $sourceSha;Assert-OwnedHash $program $programSha;Assert-OwnedHash $inventory $inventorySha
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedHash $module $c.module_sha;Assert-OwnedHash $PSCommandPath $c.phase_sha
 Write-OwnedJson (Join-Path $out 'historical-input-post.json') @{path=$input;bytes=$held.Length;sha256=$post;full_byte_read=$true;guard_still_held=$true;source_program_inventory_and_config_postpins=$true}
 if($forced -or $native.native_exit -ne 0 -or !$native.stdout_complete -or !$native.stderr_complete -or $native.output_limit -or $native.capture_fault -or $native.drain_timeout){throw 'historical_native_refused_retained'}
 $stdout=Join-Path $out 'historical-rust.stdout'
 if((Get-Item -LiteralPath $stdout).Length -gt 1MB -or $native.stderr_bytes_persisted -ne 0){throw 'historical_output_bounds_or_unexpected_stderr'}
 $result=Get-Content -LiteralPath $stdout -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if((@($result.Keys|Sort-Object)-join ',') -cne 'input_sha256,rows,status' -or $result.status -cne 'PURE_RUST_VALUE_HASH_CALIBRATION_NOT_MIGRATION_ACCEPTANCE' -or $result.input_sha256 -cne $inputSha -or @($result.rows).Count -ne 12){throw 'historical_output_envelope'}
 # Exact immutable key/version manifest, not guessed current state or old digest
 # credit. rust_value_sha256 values are NEW actual computed output of this run.
 $expected=@{
  'auth'='133';'qa/f2346eaec29b4f269cb8678234b96f43/a'='1'
  'repository/project-058796b947384b7cbfe8e5ae970fa7b3'='90'
  'repository/project-0ec3604a3037452a93719209f68dbc9a'='1'
  'repository/project-2882852256a74f148e31e5b3f919b070'='5'
  'repository/project-4e5ffc46248f4788a2cefc5fc35cd8d6'='12'
  'repository/project-69d6d080793844f08803970bfc15754d'='5'
  'repository/project-74bd969e6cd041d78f5804e57c1ee7f3'='8'
  'repository/project-795b6b388a1c436c9945fd1e4586936c'='2'
  'repository/project-8e9beb016d64419a8ee423afcbec3e65'='14'
  'repository/project-9230e2d9515c4f8cb22d5bbae2625510'='1'
  'repository/project-a08afef3d73e49e9be8b93ee7608fd96'='1'
 }
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$previous=$null;$repositories=0
 foreach($row in $result.rows){
  if((@($row.Keys|Sort-Object)-join ',') -cne 'key,rust_value_sha256,version' -or $row.key -isnot [string] -or $row.version -isnot [string] -or $row.rust_value_sha256 -isnot [string] -or !$expected.ContainsKey($row.key) -or $expected[$row.key] -cne $row.version -or !$seen.Add($row.key) -or $row.rust_value_sha256 -cnotmatch '^[0-9a-f]{64}$' -or ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$row.key) -ge 0)){throw 'historical_exact_row_manifest'}
  if($row.key.StartsWith('repository/',[StringComparison]::Ordinal)){$repositories++};$previous=$row.key
 }
 if($seen.Count -ne 12 -or $repositories -ne 10){throw 'historical_complete_rows'}
 $fixture=Join-Path $out 'historical-rust-value-hashes.json'
 [IO.File]::Copy($stdout,$fixture,$false)
 Assert-OwnedHash $fixture $native.stdout_sha256
 if([DateTime]::UtcNow -ge $end){throw 'historical_completion_deadline'}
 Write-OwnedJson (Join-Path $out 'historical-hashes-result.json') @{status='S13_PURE_RUST_HISTORICAL_HASH_REPLAY_EVIDENCE_PENDING_QA_TD';input=@{path=$input;bytes=307160864;pre_sha256=$pre;post_sha256=$post;whole_file_supervised=$true};source=@{path=$source;sha256=$sourceSha};artifact=@{path=$program;sha256=$programSha;inventory_sha256=$inventorySha;compile_config_sha256=$inv.config_sha256};native=$native;rows=12;repositories=10;fixture_path=$fixture;fixture_sha256=(Get-OwnedHash $fixture);postpins=$true;limits=@('Pure Rust serde_json::Value serialization hash domain only','Executable input_sha256 is hardcoded: only current full-file pre/post supervision binds provenance','No database/network/migration/cleanup/recovery/benchmark acceptance','No historical native execution credit transferred; new native exit0 and EOF required','Fixture needs independent QA/TD review before downstream use')}
 $complete=$true
}finally{
 if($held){$held.Dispose()}
 if(!$complete){
  if($child -and !$child.Process.HasExited){$child.Process.Kill($true);if(!$child.Process.WaitForExit(10000)){throw 'historical_final_owned_child_stop_deadline'}}
  Write-OwnedJson (Join-Path $out 'historical-hashes-failed.json') @{status='FAILED_RETAINED';automatic_retry=$false;native=$native;no_fixture_acceptance=$true}
 }
}

<#
SOURCE-ONLY DRAFT; no configuration, native process or hash replay launched.
Outer S13 owned waiting-worker Job BEFORE GO, bounded180s, private currentSID-only
config/output, exact phase/module/worker/host pins and full parentnative EOF/exit
are independent admission prerequisites. Config scope=s13-pure-rust-historical-
value-hashes; maximum_phase_seconds180; maximum_output_bytes1048576; input_bytes
307160864; fixed input_sha256/program_sha256 as above; literal input/program/
source/inventory paths; module_sha/phase_sha; pins[] for frozen build source inputs;
output_directory private NEW output; deadline_utc<=19:44:42Z. Empty env overrides;
maintained capture helper removes inherited PI_/PG/PORT/RUST_LOG before child.

Rust source fully read: accepts one path, reads full JSONL, hashes serde_json Value
document serialization, sorts all12KV, requires10repository, admits ledger only,
prints exact envelope. Its printed inputSHA IS A LITERAL, not internally verified.
Thus current guarded whole307160864B PRE+POST SHA79AE...0256D is essential. No
current rawdocument contents emitted by this wrapper. Executable immutable copy
from exact compile03inventory E715...D4C6, not mutable target/debug path. Runtime
source/example and inventorypins checked BEFORE helper import and AFTER run.
All12key/version exactmanifest checked; newly computed12Rust hashes retained as
original pure JSON stdout fixture, no PS numeric or JSON reserialization. No old
computed per-document digest used as new output. Source-read oldinventory03 only
provided immutable12key/version crosscheck, no oldDBlogin/SQL or oldPASS transfer.
Failure/native1/timeout/truncatedcapture/incompleteEOF/postpin mismatch => STOP,
retained evidence, no retry or copied successful fixture acceptance claim.
#>
