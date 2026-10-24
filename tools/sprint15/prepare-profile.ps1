param([Parameter(Mandatory)][ValidateSet('race','downgrade','lock2','browser')][string]$Case,[ValidateRange(1,99)][int]$Attempt=1,[ValidateSet('default','lifecycle','closed-stream')][string]$PhaseVariant='default',[switch]$Seal)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root=Join-Path $workspace '.local/sprint14/root'
function Hash([string]$p){(Get-FileHash -LiteralPath $p).Hash}
function Save([string]$p,$v){$b=[Text.UTF8Encoding]::new($false).GetBytes(($v|ConvertTo-Json -Depth 55));if($b.Length -gt 1MB){throw 'profile_metadata_bound'};$s=[IO.File]::Open($p,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$s.Write($b);$s.Flush($true)}finally{$s.Dispose()}}
function PrivateDir([string]$p){if(Test-Path -LiteralPath $p){throw 'profile_new_directory_required'};[void][IO.Directory]::CreateDirectory($p);$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false);$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'));[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($p),$acl)}
$spec=@{
 race=@{old='catalog-race01';phase='catalog-race-phase.ps1'}
 downgrade=@{old='catalog-downgrade01';phase='catalog-downgrade-phase.ps1'}
 lock2=@{old='full-lock2-hot03';phase='full-lock2-hot-phase.ps1'}
 browser=@{old='browser02';phase='browser-phase.ps1'}
}[$Case]
$suffix=$Attempt.ToString('00');$name='s15-'+$Case+$suffix;$dir=Join-Path $root ($name+'-inputs');$draft=Join-Path $dir 'draft01.json';$phase=Join-Path $PSScriptRoot $spec.phase
if($PhaseVariant -cin @('lifecycle','closed-stream')){if($Case -cne 'lock2'){throw 'profile_lifecycle_only_lock2'};$phase=Join-Path $PSScriptRoot $(if($PhaseVariant -ceq 'closed-stream'){'full-lock2-stream-phase.ps1'}else{'full-lock2-lifecycle-phase.ps1'})}
if(!$Seal){
 $oldPath=Join-Path $root ($spec.old+'-inputs/phase01.json')
 $c=Get-Content -LiteralPath $oldPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 $oldOut=$c.output_directory;$oldInstall=$c.install_parent
 $c.pins=@($c.pins|Where-Object {$_.path -cnotmatch '-budget-prospective01\.json$'})
 $c.phase_budget.reviews=@{}
 # Only exact tool paths present in the reviewed clone are redirected. Old raw
 # archives, canonical component binding and actual normal-run proofs stay pinned.
 function Rebase($v){
  if($v -is [string]){if($v -ceq $oldOut){return (Join-Path $root $name)};if($v -ceq $oldInstall){return (Join-Path $root ($name+'-install'))};$prefix=[IO.Path]::GetFullPath((Join-Path $workspace 'tools/sprint14')).TrimEnd('\')+'\';if($v.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$p=Join-Path $PSScriptRoot ([IO.Path]::GetFileName($v));if(Test-Path -LiteralPath $p){return $p}};return $v}
  if($v -is [Collections.IDictionary]){foreach($k in @($v.Keys)){$v[$k]=Rebase $v[$k]};return ,$v}
  if($v -is [array]){return ,@($v|ForEach-Object {Rebase $_})};return $v
 }
 $c=Rebase $c
 if($PhaseVariant -cin @('lifecycle','closed-stream')){$defaultPhase=Join-Path $PSScriptRoot $spec.phase;foreach($pin in $c.pins){if($pin.path -ceq $defaultPhase){$pin.path=$phase}}}
 $c.deadline_utc='2026-10-20T16:44:24Z';$c.epoch='S15'
 foreach($k in @('source_db','restore_db','verify_db')){if($Case -cne 'browser' -and $c.ContainsKey($k)){$c[$k]='pi_restore_s14_s15_'+$Case+'_'+$k.Replace('_db','')+$suffix}}
 $c.phase_budget.phase_sha=Hash $phase;$c.phase_budget.module_sha=Hash (Join-Path $PSScriptRoot 'resource-phase-budget.psm1')
 $proposal=Join-Path $root 's15-start-proposal01.json';$decision=Join-Path $root 's15-start-decision01.json'
 $c.phase_budget.plan_proposal_sha256=Hash $proposal;$c.phase_budget.decision=@{path=$decision;sha256=Hash $decision}
 $c.probe_sha=if($c.ContainsKey('probe')){Hash $c.probe}else{$null};if(!$c.ContainsKey('probe')){$c.Remove('probe_sha')}
 if($c.ContainsKey('bootstrap')){$c.bootstrap_sha=Hash $c.bootstrap}
 $a=Get-Content -LiteralPath $c.phase_budget.capture_allowlist.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 $a.phase_sha256=$c.phase_budget.phase_sha
 PrivateDir $dir;$allow=Join-Path $dir 'capture-allowlist01.json';Save $allow $a
 $oldAllow=$c.phase_budget.capture_allowlist.path;$c.phase_budget.capture_allowlist=@{path=$allow;sha256=Hash $allow}
 foreach($pin in $c.pins){if($pin.path -ceq $oldAllow){$pin.path=$allow};if($pin.path -ceq (Join-Path $root 'start-decision01.json')){$pin.path=$decision};if($pin.path -ceq (Join-Path $root 'start-proposal01.json')){$pin.path=$proposal};$pin.sha256=Hash $pin.path}
 Save $draft $c
}else{
 $c=Get-Content -LiteralPath $draft -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if((Hash $phase) -cne $c.phase_budget.phase_sha){throw 'profile_exact_variant_source_required'}
 foreach($role in @('Root','QA','TD')){$folder=if($role -ceq 'Root'){'root'}else{$role.ToLowerInvariant()};$p=Join-Path $workspace ('.local/sprint14/'+$folder+'/s15-start01/'+$name+'-budget-prospective01.json');$r=Get-Content -LiteralPath $p -Raw|ConvertFrom-Json -AsHashtable -DateKind String
  if($r.author_role -cne $role -or $r.verdict -cne 'PROSPECTIVE_EXACT_FULL_UNCOMPRESSED_PHASE_RESOURCE_GO'){throw 'profile_independent_budget_review'}
  foreach($key in @('scope','output_directory','install_parent','capture_reservation_bytes','phase_reservation_bytes','phase_allocation_reservation_bytes')){if($r[$key] -cne $c[$key]){throw ('profile_review_mismatch_'+$key)}}
  foreach($pair in @(@('phase_sha256',$c.phase_budget.phase_sha),@('package_sha256',$c.package_sha),@('budget_module_sha256',$c.phase_budget.module_sha),@('capture_allowlist_sha256',$c.phase_budget.capture_allowlist.sha256),@('db_wal_temp_extract_archive_bytes',$c.phase_budget.db_wal_temp_extract_archive_bytes))){if($r[$pair[0]] -cne $pair[1]){throw 'profile_review_binding'}}
  if(!$r.all_other_writers_quiet){throw 'profile_baseline_quiet_required'};$pin=@{path=$p;sha256=Hash $p};$c.phase_budget.reviews[$role]=$pin;$c.pins+=,$pin
 }
 foreach($pin in $c.pins){if((Hash $pin.path) -cne $pin.sha256){throw 'profile_pinned_input_changed'}}
 PrivateDir $c.output_directory;$pc=Join-Path $dir 'phase01.json';Save $pc $c
 $runtime=Get-Content -LiteralPath (Join-Path $root ($spec.old+'-inputs/runtime01.json')) -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 $runtime.arguments=@('-NoProfile','-File',$phase,'-PhaseConfig',$pc,'-PhaseConfigSha',(Hash $pc));$runtime.output_directory=$c.output_directory;$runtime.deadline_utc=$c.deadline_utc;$runtime.supervisor_sha256=Hash (Join-Path $PSScriptRoot 'run-owned-process.ps1');$runtime.inputs=@($c.pins)+@(@{path=$pc;sha256=Hash $pc})
 # oldInstall is deliberately sourced from the immutable template in Seal mode.
 $template=Get-Content -LiteralPath (Join-Path $root ($spec.old+'-inputs/phase01.json')) -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 foreach($ready in $runtime.ready_processes){$ready.path=$ready.path.Replace($template.install_parent,$c.install_parent);if($ready.ContainsKey('datadir')){$ready.datadir=$ready.datadir.Replace($template.install_parent,$c.install_parent)}}
 $rc=Join-Path $dir 'runtime01.json';Save $rc $runtime
}
@{case=$Case;draft=$draft;draft_sha256=Hash $draft;sealed=[bool]$Seal;runtime_started=$false}|ConvertTo-Json -Compress
