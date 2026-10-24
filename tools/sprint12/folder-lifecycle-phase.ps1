param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw | ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output_directory
if($c.app_port -ne 3096 -or $c.pg_port -ne 5464 -or $c.database -cne 'process_intelligence'){throw 'lifecycle_scope'}
$package=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $package 'startup01'
 [void](Wait-OwnedStockService $service)
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.http_probe,$PhaseConfig,'seed') $c.workspace $c.output_directory 'stock-seed' @{} 180 1MB)
 $secret=Get-Content (Join-Path $package '.local/postgres-private.json') -Raw | ConvertFrom-Json -DateKind String
 $psql=Join-Path $package 'runtime/postgresql/pgsql/bin/psql.exe'
 for($step=1;$step -le 18;$step++){
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$PhaseConfig,[string]$step,'pre') $c.workspace $c.output_directory ('step-'+$step+'-read-pre') @{} 30 1MB)
  $connectionArgs=@('-h','127.0.0.1','-p','5464','-U','pi_admin','-w','-d','process_intelligence','-At','-v','ON_ERROR_STOP=1','-f',$c.capture_sql)
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $connectionArgs $package $c.output_directory ('step-'+$step+'-pre') @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$PhaseConfig,[string]$step) $c.workspace $c.output_directory ('step-'+$step+'-http') @{} 30 1MB)
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $connectionArgs $package $c.output_directory ('step-'+$step+'-post') @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.oracle,$c.output_directory,[string]$step) $c.workspace $c.output_directory ('step-'+$step+'-oracle') @{} 30 1MB)
 }
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $c.output_directory 'lifecycle-result.json') @{status='FINITE_FOLDER_LIFECYCLE_READY_FOR_REVIEW';steps=18;full_pre_derived_state_steps=18;product_version='0.7.2';limits=@('Actual HTTP folder/resource lifecycle only; no literal project movement acceptance','No browser/Datastar interaction claim','No concurrent final HTTP instruction hold claim','No complete original R3-02 acceptance')}
}finally{
 $secret=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
