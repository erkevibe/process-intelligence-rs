param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw | ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$fixed=Join-Path $c.workspace '.local/sprint12/root/fresh-mixed-replay01'
if($c.output_directory -cne $fixed -or $c.deadline_utc -cne '2026-10-19T13:52:56Z' -or $c.phases.Count -ne 4){throw 'fresh_replay_fixed_scope'}
Assert-OwnedPrivateDirectory $fixed
$end=[DateTime]::UtcNow.AddSeconds(1800)
$freeze=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($end -gt $freeze){$end=$freeze}
$names=@('project01','resource01','retention01','recovery01')
$statuses=@('FINITE_PROJECT_HTTP_LIFECYCLE_READY_FOR_REVIEW','FINITE_RESOURCE_HTTP_LIFECYCLE_READY_FOR_REVIEW','MIXED_REPOSITORY_AND_FORMER_OWNER_RETENTION_READY_FOR_REVIEW','MIXED_BACKUP_CRASH_RECOVERY_READY_FOR_REVIEW')
$results=@('project-result.json','resource-result.json','mixed-retention-result.json','mixed-recovery-result.json')
$completed=@()
for($i=0;$i -lt 4;$i++){
 if([DateTime]::UtcNow -ge $end -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'fresh_replay_phase_budget'}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $phase=$c.phases[$i];$name=$names[$i];$directory=Join-Path $fixed $name
 if($phase.name -cne $name){throw 'fresh_replay_order'}
 Assert-OwnedHash $phase.template $phase.template_sha256
 Assert-OwnedHash $phase.script $phase.script_sha256
 $p=Get-Content -LiteralPath $phase.template -Raw | ConvertFrom-Json -AsHashtable -DateKind String
 if($p.output_directory -cne $directory -or $p.install_parent -cne (Join-Path $fixed 'project01/install01') -or $p.app_port -ne 3096 -or $p.pg_port -ne 5464 -or $p.database -cne 'process_intelligence'){throw 'fresh_replay_template_scope'}
 if(Test-Path -LiteralPath $directory){throw 'fresh_replay_output_exists'}
 [void](New-OwnedPrivateDirectory $directory)
 $bridges=@()
 if($i -gt 0){
  $previous=$completed[$i-1]
  Assert-OwnedHash $previous.result $previous.result_sha256
  Assert-OwnedHash $previous.native $previous.native_sha256
  foreach($bridge in $phase.bridges){
   $expected=Join-Path (Join-Path $fixed $names[$i-1]) $bridge.file
   if($p[$bridge.field] -cne $expected){throw 'fresh_replay_bridge_scope'}
   Assert-OwnedNoReparse $expected
   $hash=Get-OwnedHash $expected
   $p.pins+=@{path=$expected;sha256=$hash}
   $bridges+=@{field=$bridge.field;path=$expected;sha256=$hash;producer_native_sha256=$previous.native_sha256;producer_result_sha256=$previous.result_sha256}
  }
  $p.pins+=@{path=$previous.result;sha256=$previous.result_sha256}
  $p.pins+=@{path=$previous.native;sha256=$previous.native_sha256}
 }
 foreach($pin in $p.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $generated=Join-Path $directory 'phase-config.json'
 Write-OwnedJson $generated $p
 $sha=Get-OwnedHash $generated
 Write-OwnedJson (Join-Path $directory 'bridge-admission.json') @{name=$name;phase_config_sha256=$sha;script_sha256=$phase.script_sha256;bridges=$bridges;scope='Closed native0/full EOF producer before dynamic output hash binding; same fresh owned installation only'}
 $seconds=[Math]::Min(1800,[Math]::Floor(($end-[DateTime]::UtcNow).TotalSeconds))
 if($seconds -lt 1){throw 'fresh_replay_time_exhausted'}
 $native=Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$phase.script,'-PhaseConfig',$generated,'-PhaseConfigSha',$sha) $c.workspace $fixed ($name+'-phase') @{} $seconds 4MB
 if($native.native_exit -ne 0 -or -not $native.stdout_complete -or -not $native.stderr_complete -or $native.output_limit -or $native.capture_fault){throw 'fresh_replay_incomplete_phase'}
 $result=Join-Path $directory $results[$i]
 $r=Get-Content -LiteralPath $result -Raw | ConvertFrom-Json -AsHashtable -DateKind String
 if($r.status -cne $statuses[$i]){throw 'fresh_replay_result_status'}
 $nativePath=Join-Path $fixed ($name+'-phase.process.json')
 $completed+=@{name=$name;phase_config_sha256=$sha;result=$result;result_sha256=Get-OwnedHash $result;native=$nativePath;native_sha256=Get-OwnedHash $nativePath}
 Write-OwnedJson (Join-Path $fixed ($name+'-closed.json')) $completed[$i]
}
Write-OwnedJson (Join-Path $fixed 'fresh-replay-result.json') @{status='FRESH_MIXED_FOUR_PHASE_REPLAY_READY_FOR_INDEPENDENT_REVIEW';phases=$completed;scope='New installation; sequential actual project/resource/retention/recovery; no retry of failed or old databases; not independent acceptance'}
