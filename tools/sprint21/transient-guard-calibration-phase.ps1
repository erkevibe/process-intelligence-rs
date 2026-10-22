param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'continuation-resource-guard.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output
$target=Join-Path $c.workspace '.local/sprint21/root/target'
$fixture=Join-Path $target 'guard-calibration01'
if(Test-Path -LiteralPath $fixture){throw 'fresh_guard_fixture_required'}
# Synchronize with an actual completed outer sample, leaving its unchanged20s
# interval intact. The deliberate deny fixture is restored within a5s budget.
$until=[DateTimeOffset]::UtcNow.AddSeconds(32)
while(!(Test-Path -LiteralPath (Join-Path $c.output 'capacity-control-ready.json'))){if([DateTimeOffset]::UtcNow -ge $until){throw 'guard_marker_timeout'};Start-Sleep -Milliseconds 50}
[void](New-OwnedPrivateDirectory $fixture)
$denied=Join-Path $fixture 'existing-denied.bin';$locked=Join-Path $fixture 'existing-locked.bin'
[IO.File]::WriteAllBytes($denied,[byte[]]@(7));[IO.File]::WriteAllBytes($locked,[byte[]]@(8))
$timer=[Diagnostics.Stopwatch]::StartNew();$hold=$null;$originalAcl=$null;$restored=$false;$deniedError=$null
try{
 $originalAcl=Get-Acl -LiteralPath $denied
 $changed=Get-Acl -LiteralPath $denied
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 $changed.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::ReadData,[Security.AccessControl.AccessControlType]::Deny))
 Set-Acl -LiteralPath $denied -AclObject $changed
 try{$stream=[IO.File]::Open($denied,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);$stream.Dispose();throw 'denied_fixture_was_readable'}catch{
  $deniedError=$_.Exception
  if(!($deniedError.GetBaseException() -is [UnauthorizedAccessException])){throw}
 }
 if(Test-S20GoneTargetError $deniedError $denied $target){throw 'existing_denied_skipped'}
 [void][IO.File]::GetAttributes($denied)
 Set-Acl -LiteralPath $denied -AclObject $originalAcl;$restored=$true
 # Exact literal file deletion; resolved path is inside the verified fresh fixture.
 if(!([IO.Path]::GetFullPath($denied)).StartsWith(([IO.Path]::GetFullPath($fixture)+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'fixture_containment'}
 [IO.File]::Delete($denied)
 if(!(Test-S20GoneTargetError $deniedError $denied $target)){throw 'genuinely_missing_target_not_recognized'}
 if(Test-S20GoneTargetError $deniedError (Join-Path $c.output 'missing-outside-target.bin') $target){throw 'outside_target_skipped'}
 $hold=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $lockError=$null
 try{$stream=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);$stream.Dispose();throw 'locked_fixture_was_readable'}catch{$lockError=$_.Exception}
 if(!$lockError -or !($lockError.GetBaseException() -is [IO.IOException]) -or (($lockError.GetBaseException().HResult -band 0xFFFF) -notin @(32,33))){throw 'actual_sharing_error_not_observed'}
 if(Test-S20GoneTargetError $lockError $locked $target){throw 'existing_locked_skipped'}
}finally{
 if($hold){$hold.Dispose()}
 if($originalAcl -and !$restored){Set-Acl -LiteralPath $denied -AclObject $originalAcl}
}
$timer.Stop();if($timer.Elapsed.TotalSeconds -gt 5){throw 'deliberate_fixture_window_exceeded'}
$scan=[Diagnostics.Stopwatch]::StartNew();$sample=Get-S20ResourceSnapshot (Join-Path $c.workspace '.local/sprint21') $target;$scan.Stop()
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'guard-proof.json') @{status='ACTUAL_TRANSIENT_TARGET_REFUSAL_CONTROLS';existing_actual_read_denial_refused=$true;actual_denial_then_deleted_target_recognized=$true;outside_target_refused=$true;existing_actual_sharing_lock_refused=$true;deliberate_fixture_seconds=$timer.Elapsed.TotalSeconds;full_native_sample_seconds=$scan.Elapsed.TotalSeconds;sample=$sample;native_metric_unchanged=$true;timeout25s_unchanged=$true;compile04_child_capture_gap_not_reconstructed=$true}
