param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output_directory
if($c.app_port -ne 3096 -or $c.pg_port -ne 5464 -or $c.database -cne 'process_intelligence'){throw 'ui_route_scope'}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $pkg 'startup01';$ready=Wait-OwnedStockService $service
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.http_probe,$PhaseConfig,'seed') $c.workspace $c.output_directory 'ui-http-fixture-seed' @{} 180 1MB)
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.model_seed,$PhaseConfig) $c.workspace $c.output_directory 'ui-model-fixture-seed' @{} 30 1MB)
 Write-OwnedJson (Join-Path $c.output_directory 'ui-ready.json') @{status='OWNED_FRESH_UI_READY';url='http://127.0.0.1:3096';package=$pkg;limits=@('Browser actions must be separately recorded; ready does not imply acceptance')}
 $end=[DateTime]::UtcNow.AddSeconds(600)
 $signal=Join-Path $c.output_directory 'ui-complete.json'
 while(-not(Test-Path -LiteralPath $signal)){
  if([DateTime]::UtcNow -ge $end -or [DateTime]::UtcNow -ge [DateTime]'2026-10-19T13:52:56Z' -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB){throw 'ui_route_wait_limit'}
  if($service.Coordinator.Process.HasExited -or $service.Coordinator.OutCapture.LimitReached -or $service.Coordinator.ErrCapture.LimitReached -or $service.Coordinator.OutCapture.Pump.IsFaulted -or $service.Coordinator.ErrCapture.Pump.IsFaulted){throw 'ui_route_service_capture'}
  foreach($retained in $service.Processes){
   $retained.Process.Refresh()
   if($retained.Process.HasExited -or -not $service.Job.Member($retained.Handle) -or $retained.Process.StartTime.ToUniversalTime().ToString('o') -cne $retained.Creation){throw 'ui_route_retained_service_identity'}
  }
  Start-Sleep -Milliseconds 200
 }
 Assert-OwnedNoReparse $signal
 if((Get-Item $signal).Length -gt 64KB){throw 'ui_signal_bound'}
 $completion=Get-Content $signal -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($completion.status -cne 'BROWSER_ACTIONS_CLOSED' -or -not $completion.proof_file -or -not $completion.proof_sha256){throw 'ui_signal_schema'}
 $proof=Get-OwnedCanonicalPath $completion.proof_file
 if(-not $proof.StartsWith($c.output_directory.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'ui_proof_boundary'}
 Assert-OwnedNoReparse $proof
 Assert-OwnedHash $proof $completion.proof_sha256
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json -DateKind String
 $psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe'
 [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha @('-h','127.0.0.1','-p','5464','-U','pi_admin','-w','-d','process_intelligence','-At','-v','ON_ERROR_STOP=1','-f',$c.capture_sql) $pkg $c.output_directory 'ui-final-managed' @{PGPASSWORD=$secret.admin_password} 30 16MB)
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $c.output_directory 'ui-route-result.json') @{status='OWNED_UI_ROUTE_CLOSED_READY_FOR_REVIEW';proof_sha256=$completion.proof_sha256;limits=@('Browser observations and final state only; no per-click whole-database atomicity proof')}
}finally{
 $secret=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
