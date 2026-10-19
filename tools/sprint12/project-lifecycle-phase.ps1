param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw | ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output_directory
if($c.app_port -ne 3096 -or $c.pg_port -ne 5464 -or $c.database -cne 'process_intelligence'){throw 'project_lifecycle_scope'}
$package=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $package 'startup01'
 [void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $package '.local/postgres-private.json') -Raw | ConvertFrom-Json -DateKind String
 $psql=Join-Path $package 'runtime/postgresql/pgsql/bin/psql.exe'
 $connectionArgs=@('-h','127.0.0.1','-p','5464','-U','pi_admin','-w','-d','process_intelligence','-At','-v','ON_ERROR_STOP=1','-f',$c.capture_sql)
 for($step=1;$step -le 32;$step++){
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $connectionArgs $package $c.output_directory ('project-'+$step+'-pre') @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$PhaseConfig,[string]$step) $c.workspace $c.output_directory ('project-'+$step+'-http') @{} 60 1MB)
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $connectionArgs $package $c.output_directory ('project-'+$step+'-post') @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.oracle,$c.output_directory,[string]$step) $c.workspace $c.output_directory ('project-'+$step+'-oracle') @{} 30 1MB)
 }
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $c.output_directory 'project-result.json') @{status='FINITE_PROJECT_HTTP_LIFECYCLE_READY_FOR_REVIEW';steps=32;full_pre_derived_state_steps=32;limits=@('Empty project backup restore, durable folder payload deletion; not all possible payload combinations','Generated IDs, salts, timestamps and token expiry observed with independent format/crypto/time bounds','Actual HTTP project lifecycle; no final HTTP instruction hold or browser claim','Literal movement of a project remains OPEN','No full R3/R2-R5 or enterprise acceptance')}
}finally{
 $secret=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
