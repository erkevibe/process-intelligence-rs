param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw | ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output_directory
if($c.app_port -ne 3096 -or $c.pg_port -ne 5464 -or $c.database -cne 'process_intelligence'){throw 'mixed_retention_scope'}
Test-OwnedPackageTree $c.package $c.manifest_sha $true
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $c.package 'startup01'
 [void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $c.package '.local/postgres-private.json') -Raw | ConvertFrom-Json -DateKind String
 $psql=Join-Path $c.package 'runtime/postgresql/pgsql/bin/psql.exe'
 $connectionArgs=@('-h','127.0.0.1','-p','5464','-U','pi_admin','-w','-d','process_intelligence','-At','-v','ON_ERROR_STOP=1','-f',$c.capture_sql)
 foreach($mode in @('repo512','repo513','survivor512','survivor513')){
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $connectionArgs $c.package $c.output_directory ($mode+'-pre') @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$PhaseConfig,$mode) $c.workspace $c.output_directory ($mode+'-http') @{} 900 4MB)
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $connectionArgs $c.package $c.output_directory ($mode+'-post') @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.compare,$c.output_directory,$mode) $c.workspace $c.output_directory ($mode+'-compare') @{} 30 1MB)
 }
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $c.output_directory 'mixed-retention-result.json') @{status='MIXED_REPOSITORY_AND_FORMER_OWNER_RETENTION_READY_FOR_REVIEW';boundaries=@('repository512','repository513','former-owner512','former-owner513');limits=@('Boundary full PRE-derived state; transient victim create/archive per-commit semantics covered separately by project32','Actual HTTP mutations only, no SQL seeded positive audit evidence','No browser/physical erasure/universal enterprise retention claim')}
}finally{
 $secret=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
