param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output_directory
if($c.app_port -ne 3096 -or $c.pg_port -ne 5464 -or $c.database -cne 'process_intelligence'){throw 'stock_cas_scope'}
Test-OwnedPackageTree $c.package $c.manifest_sha $true
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $c.package 'startup01';[void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $c.package '.local/postgres-private.json') -Raw|ConvertFrom-Json -DateKind String
 $psql=Join-Path $c.package 'runtime/postgresql/pgsql/bin/psql.exe'
 $argsSql=@('-h','127.0.0.1','-p','5464','-U','pi_admin','-w','-d','process_intelligence','-At','-v','ON_ERROR_STOP=1','-f',$c.capture_sql)
 [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $argsSql $c.package $c.output_directory 'cas-pre' @{PGPASSWORD=$secret.admin_password} 30 16MB)
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$PhaseConfig) $c.workspace $c.output_directory 'cas-http' @{} 60 1MB)
 [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $argsSql $c.package $c.output_directory 'cas-post' @{PGPASSWORD=$secret.admin_password} 30 16MB)
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.oracle,$c.output_directory) $c.workspace $c.output_directory 'cas-oracle' @{} 30 1MB)
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $c.output_directory 'stock-cas-result.json') @{status='STOCK_HTTP_CAS_READY_FOR_INDEPENDENT_REVIEW';scope='Two overlapping stock HTTP rename requests with same revision; one commit and one specific conflict; whole database/Auth/sequence expected state'}
}finally{
 $secret=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
