param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# All fixtures are synthetic; no path under the actual pgdata11 is modified.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'guard_control_config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'continuation-resource-guard.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$root=Join-Path $c.workspace '.local/sprint21/root'
if($c.output -cne (Join-Path $root 'capacity-guard-control01')){throw 'guard_control_exact_output'}
Assert-OwnedPrivateDirectory $c.output
$fixture=New-OwnedPrivateDirectory (Join-Path $c.output 'fixture')
$syntheticRoot=Join-Path $fixture 'synthetic-root'
$results=[Collections.Generic.List[object]]::new();$held=$null;$link=$null;$success=$false
function Bounds {if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc -or (Get-PSDrive C).Free -lt 8GB){throw 'guard_control_time_or_free_floor'}}
function Directory([string]$Path){
 $canonical=[IO.Path]::GetFullPath($Path);$prefix=[IO.Path]::GetFullPath($fixture)+[IO.Path]::DirectorySeparatorChar
 if(!$canonical.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'guard_control_fixture_bounds'}
 $relative=[IO.Path]::GetRelativePath($fixture,$canonical);$current=$fixture
 foreach($part in ($relative -split '[\\/]')){$current=Join-Path $current $part;if(Test-Path -LiteralPath $current){Assert-OwnedNoReparse $current}else{[void](New-OwnedPrivateDirectory $current)}}
 return $canonical
}
function Missing([string]$Path){
 try{[void][IO.File]::GetAttributes($Path)}catch{
  $errorObject=$_.Exception.GetBaseException()
  if($errorObject -is [IO.FileNotFoundException] -or $errorObject -is [IO.DirectoryNotFoundException]){return $errorObject}
  throw
 }
 throw 'guard_control_expected_real_absence'
}
function Probe([string]$Name,[string]$Path,[Exception]$ErrorObject,[bool]$Expected,[string]$Origin){
 Bounds
 $actual=Test-S21GonePgInternalInitError $ErrorObject $Path $syntheticRoot
 $results.Add(@{name=$Name;path_relative_to_fixture=[IO.Path]::GetRelativePath($fixture,$Path);original_exception_type=$ErrorObject.GetType().FullName;original_exception_origin=$Origin;expected=$Expected;actual=$actual;status=if($actual -eq $Expected){'PASS'}else{'FAIL'}})
 if($actual -ne $Expected){throw ('guard_control_mismatch_'+$Name)}
}
try{
 Bounds
 if(!$c.ContainsKey('capacity_control_marker') -or $c.capacity_control_marker -ne $true){throw 'guard_control_actual_periodic_marker_required'}
 # Prepare only benign directories/files before waiting for the first completed
 # periodic sample. The deliberate reparse/read-denial probes run immediately.
 $baseParent=Directory (Join-Path $syntheticRoot 'root/pgdata11/base')
 $target=Directory (Join-Path $fixture 'reparse-target');$link=Join-Path $baseParent '15'
 $lockedParent=Directory (Join-Path $baseParent '8');$lockedPath=Join-Path $lockedParent 'pg_internal.init'
 $lockedMissing=Missing $lockedPath
 [IO.File]::WriteAllText($lockedPath,'x',[Text.UTF8Encoding]::new($false))
 $markerPath=Join-Path $c.output 'capacity-control-ready.json'
 $markerWaitUntil=[DateTimeOffset]::UtcNow.AddSeconds(30);$marker=$null
 while([DateTimeOffset]::UtcNow -lt $markerWaitUntil){
  Bounds
  if(Test-Path -LiteralPath $markerPath){
   Assert-OwnedNoReparse $markerPath
   if((Get-Item -LiteralPath $markerPath).Length -gt 16KB){throw 'guard_control_marker_capacity'}
   $raw=[IO.File]::ReadAllText($markerPath)
   if($raw.Trim()){
    try{$marker=$raw|ConvertFrom-Json -AsHashtable -DateKind String}catch{$marker=$null}
    if($marker){break}
   }
  }
  Start-Sleep -Milliseconds 20
 }
 if(!$marker -or !$marker.ContainsKey('utc')){throw 'guard_control_actual_periodic_marker_timeout'}
 $markerUtc=[DateTimeOffset]::ParseExact([string]$marker.utc,'o',[Globalization.CultureInfo]::InvariantCulture)
 $windowEnd=$markerUtc.AddSeconds(5);$windowStarted=[DateTimeOffset]::UtcNow
 if($windowStarted -lt $markerUtc -or $windowStarted -ge $windowEnd){throw 'guard_control_marker_stale_or_future'}
 $markerSha=Get-OwnedHash $markerPath
 $linkCreated=$false
 try{
  if([DateTimeOffset]::UtcNow -ge $windowEnd){throw 'guard_control_reparse_window_expired_before_create'}
  try{[void][IO.Directory]::CreateSymbolicLink($link,$target);$linkCreated=$true}catch{
   $cause=$_.Exception.GetBaseException();$code=$cause.HResult -band 0xffff
   if($cause -is [UnauthorizedAccessException] -or ($cause -is [IO.IOException] -and $code -in @(1,50,1314))){$results.Add(@{name='actual-reparse-parent';status='SKIP';reason='OS denied or lacks symbolic-link capability';exception_type=$cause.GetType().FullName;native_hresult=$cause.HResult;no_reparse_pass_claim=$true})}else{throw}
  }
  if($linkCreated){
   if(!([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint)){throw 'guard_control_actual_reparse_not_created'}
   $through=Join-Path $link 'pg_internal.init'
   Probe 'actual-reparse-parent' $through (Missing $through) $false 'actual directory symbolic link, created only within post-sample five-second window'
  }
 }finally{
  if($linkCreated){
   if(!([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint)){throw 'guard_control_link_identity_changed'}
   [IO.Directory]::Delete($link,$false)
  }
  $link=$null
 }
 $reparseRemovedUtc=[DateTimeOffset]::UtcNow
 if($reparseRemovedUtc -ge $windowEnd){throw 'guard_control_reparse_window_overrun'}
 if([DateTimeOffset]::UtcNow -ge $windowEnd){throw 'guard_control_sharing_window_expired_before_lock'}
 $held=[IO.File]::Open($lockedPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $sharing=$null
  try{$attempt=[IO.File]::OpenRead($lockedPath);$attempt.Dispose()}catch{$sharing=$_.Exception.GetBaseException()}
  if($sharing -isnot [IO.IOException]){throw 'guard_control_expected_actual_sharing_error'}
  Probe 'actual-sharing-error-existing-file' $lockedPath $sharing $false 'actual exclusive-handle/OpenRead sharing failure within post-sample window'
  Probe 'locked-existing-file-original-missing' $lockedPath $lockedMissing $false 'actual earlier absence replay; file now exists and is locked'
 }finally{$held.Dispose();$held=$null}
 $windowFinished=[DateTimeOffset]::UtcNow
 if($windowFinished -ge $windowEnd){throw 'guard_control_transient_window_overrun'}
 Assert-OwnedHash $markerPath $markerSha
 Write-OwnedJson (Join-Path $c.output 'transient-probe-window.json') @{marker_sha256=$markerSha;actual_completed_periodic_sample_utc=$markerUtc.ToUniversalTime().ToString('o');window_started_utc=$windowStarted.ToUniversalTime().ToString('o');reparse_removed_utc=$reparseRemovedUtc.ToUniversalTime().ToString('o');locks_released_utc=$windowFinished.ToUniversalTime().ToString('o');marker_to_finish_ms=($windowFinished-$markerUtc).TotalMilliseconds;required_maximum_ms=5000;next_outer_sample_interval_ms=20000;outer_sample_skipped_or_rescheduled=$false;all_deliberate_transients_removed=$true}
 $validParent=Directory (Join-Path $syntheticRoot 'root/pgdata11/base/5')
 $valid=Join-Path $validParent 'pg_internal.init'
 $missingError=Missing $valid
 Probe 'actual-missing-exact-oid-file' $valid $missingError $true 'actual GetAttributes absence'
 Probe 'actual-directory-missing-error-type-valid-file' $valid ([IO.DirectoryNotFoundException]::new('controlled original missing-directory error')) $true 'controlled exception constructor; fresh absence is actually probed'
 [IO.File]::WriteAllText($valid,'x',[Text.UTF8Encoding]::new($false))
 Probe 'file-now-exists-after-original-missing' $valid $missingError $false 'actual earlier GetAttributes absence replay; file now exists'
 $otherParent=Directory (Join-Path $syntheticRoot 'root/pgdata11/base/6');$other=Join-Path $otherParent 'pg_internal.init'
 Probe 'unauthorized-original-error-even-absent' $other ([UnauthorizedAccessException]::new('controlled unauthorized original error')) $false 'controlled exception constructor; no OS access-denial claim'
 Probe 'generic-io-original-error-even-absent' $other ([IO.IOException]::new('controlled unrelated I/O original error')) $false 'controlled exception constructor; no OS sharing-error claim'
 foreach($case in @(
  @('wrong-cluster','root/pgdata12/base/5/pg_internal.init'),
  @('wrong-basename','root/pgdata11/base/5/pg_internal.init.tmp'),
  @('zero-oid','root/pgdata11/base/0/pg_internal.init'),
  @('leading-zero-oid','root/pgdata11/base/05/pg_internal.init'),
  @('overflow-oid','root/pgdata11/base/4294967296/pg_internal.init'),
  @('extra-nesting','root/pgdata11/base/5/nested/pg_internal.init')
 )){
  $path=Join-Path $syntheticRoot $case[1];[void](Directory (Split-Path -Parent $path))
  Probe $case[0] $path (Missing $path) $false 'actual GetAttributes absence at disallowed path'
 }
 $outsideParent=Directory (Join-Path $fixture 'outside-root/root/pgdata11/base/5');$outside=Join-Path $outsideParent 'pg_internal.init'
 Probe 'outside-synthetic-root' $outside (Missing $outside) $false 'actual GetAttributes absence outside trusted synthetic root'
 $missingParentPath=Join-Path $syntheticRoot 'root/pgdata11/base/7/pg_internal.init'
 Probe 'missing-parent-directory' $missingParentPath (Missing $missingParentPath) $false 'actual missing parent; parent-presence guard must refuse'
 # Locks and links have been removed. Benign nonreparse fixtures remain as evidence.
 [void](Directory (Join-Path $syntheticRoot 'root/target'))
 $synthetic=Get-S20ResourceSnapshot $syntheticRoot (Join-Path $syntheticRoot 'root/target')
 Write-OwnedJson (Join-Path $c.output 'synthetic-scan.json') $synthetic
 $actual=Get-S20ResourceSnapshot (Join-Path $c.workspace '.local/sprint21') (Join-Path $root 'target')
 if($actual.root_logical_bytes -gt (8GB-512MB) -or $actual.root_allocation_bytes -gt (8GB-512MB) -or $actual.logical_bytes -gt (12GB-512MB) -or $actual.allocation_bytes -gt (12GB-512MB)){throw 'guard_control_actual_scan_headroom'}
 Write-OwnedJson (Join-Path $c.output 'actual-sprint-scan.json') $actual
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $success=$true
}catch{
 $primary=$_;try{Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{exception_type=$primary.Exception.GetType().FullName;message=$primary.Exception.Message;position=$primary.InvocationInfo.PositionMessage;script_stack_trace=$primary.ScriptStackTrace;utc=[DateTimeOffset]::UtcNow.ToString('o')}}catch{Write-Warning ('guard_control_failure_receipt_diagnostic: '+$_.Exception.Message)};throw $primary
}finally{
 if($held){$held.Dispose()}
 if($link -and (Test-Path -LiteralPath $link)){
  $canonical=[IO.Path]::GetFullPath($link)
  if(!$canonical.StartsWith(([IO.Path]::GetFullPath($fixture)+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase) -or !([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint)){throw 'guard_control_cleanup_link_identity'}
  [IO.Directory]::Delete($link,$false)
 }
 Write-OwnedJson (Join-Path $c.output 'control-results.json') @{status=if($success){'ACTUAL_GUARD_CONTROLS_AND_FULL_SCAN_COMPLETED'}else{'FAILED'};cases=$results.ToArray();real_pgdata_modified=$false;synthetic_nonreparse_fixtures_retained=$true;locks_released_and_reparse_links_removed=$true;timeout_entry_caps_byte_budgets_unchanged=$true;config_sha256=$PhaseConfigSha}
}
