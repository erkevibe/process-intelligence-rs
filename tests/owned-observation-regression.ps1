param([Parameter(Mandatory)][string]$Output,[Parameter(Mandatory)][string]$Node,[Parameter(Mandatory)][string]$NodeSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../tools/owned-runtime.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../tools/owned-phase-support.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../tools/owned-observation-schedule.psm1') -DisableNameChecking
Assert-OwnedPrivateDirectory $Output
$fixture=Join-Path $PSScriptRoot 'owned-observation-fixture.cjs';$records=@()
foreach($mode in @('early-five','scheduled')){
 $p=Start-OwnedCapturedProcess -Program $Node -ProgramSha256 $NodeSha -Arguments @($fixture) -WorkingDirectory (Split-Path $PSScriptRoot -Parent) -OutputDirectory $Output -Label $mode -MaxOutputBytes 1MB
 $clock=[Diagnostics.Stopwatch]::StartNew();$schedule=@{attempts=0;next_ms=0;interval_ms=1000;maximum_attempts=30};$early=0;$found=$false;$times=@()
 while(-not $p.Process.WaitForExit(100)){
  $due=if($mode -ceq 'early-five'){$early -lt 5}else{Get-OwnedObservationDue $schedule $clock.Elapsed.TotalMilliseconds}
  if($due){
   $early++;$prefix=Get-OwnedLivePrefix ($p.Base+'.stdout');$ready=$prefix.Contains('ready');$times+=@{elapsed_ms=$clock.Elapsed.TotalMilliseconds;ready=$ready;child_alive=(-not $p.Process.HasExited)}
   if($ready){$found=$true}
   if($mode -ceq 'early-five'){Start-Sleep -Milliseconds 150}
  }
  if($clock.Elapsed.TotalSeconds -gt 10){$p.Process.Kill();throw 'observation_regression_timeout'}
 }
 $native=Complete-OwnedCapturedProcess $p
 if($native.native_exit -ne 0 -or -not $native.stdout_complete -or -not $native.stderr_complete){throw 'observation_fixture_native_failed'}
 $records+=@{mode=$mode;found_live_ready=$found;probes=$times;native=$native}
}
if($records[0].found_live_ready -or -not $records[1].found_live_ready -or $records[0].probes.Count -ne 5){throw 'observation_causal_regression'}
Write-OwnedJson (Join-Path $Output 'observation-result.json') @{status='FINITE_DELAYED_OBSERVATION_REGRESSION_PASSED';records=$records;scope='Old early-five probes miss delayed readiness; actual shared monotonic schedule observes it while child alive. No historical backend fabrication or SQL/product acceptance'}
