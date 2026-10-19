param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output_directory
if($c.app_port -ne 3096 -or $c.pg_port -ne 5464 -or $c.database -cne 'process_intelligence'){throw 'audit_access_scope'}
Test-OwnedPackageTree $c.package $c.manifest_sha $true
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $c.package 'startup01';[void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $c.package '.local/postgres-private.json') -Raw|ConvertFrom-Json -DateKind String
 $psql=Join-Path $c.package 'runtime/postgresql/pgsql/bin/psql.exe'
 $argsSql=@('-h','127.0.0.1','-p','5464','-U','pi_admin','-w','-d','process_intelligence','-At','-v','ON_ERROR_STOP=1','-f',$c.capture_sql)
 foreach($step in 1..4){
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $argsSql $c.package $c.output_directory ("project-$step-pre") @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$PhaseConfig,[string]$step) $c.workspace $c.output_directory ("project-$step-http") @{} 30 1MB)
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $argsSql $c.package $c.output_directory ("project-$step-post") @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.project_oracle,$c.output_directory,[string]$step) $c.workspace $c.output_directory ("project-$step-oracle") @{} 30 1MB)
 }
 [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $argsSql $c.package $c.output_directory 'exports-pre' @{PGPASSWORD=$secret.admin_password} 30 16MB)
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$PhaseConfig,'exports') $c.workspace $c.output_directory 'exports-http' @{} 60 1MB)
 [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha $argsSql $c.package $c.output_directory 'exports-post' @{PGPASSWORD=$secret.admin_password} 30 16MB)
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.state_compare,(Join-Path $c.output_directory 'exports-pre.stdout'),(Join-Path $c.output_directory 'exports-post.stdout'),'exact') $c.workspace $c.output_directory 'exports-conservation' @{} 30 1MB)
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $c.output_directory 'audit-access-result.json') @{status='FOUR_ROLE_AUDIT_WITNESS_ACCESS_READY_FOR_REVIEW';preparatory_commits=4;exports=4;deleted_project_refusals=4;limits=@('Actual owner/editor/viewer share active project; foreign actor remains outside','Positive former-owner witness exists only for its actor; export expected entirely from raw PRE','Finite access proof; no universal security audit claim')}
}finally{
 $secret=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
