param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$admitted=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $admitted.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedHash $admitted.migration_helper $admitted.migration_helper_sha
. $admitted.migration_helper -PhaseConfig $PhaseConfig -PhaseConfigSha $PhaseConfigSha
if((Get-Content (Join-Path $out 'migration-result.json') -Raw|ConvertFrom-Json).status -cne 'FINITE_SPECIFIC_REFUSAL_AND_SMALL_CAUSAL_MIGRATION_EVIDENCE_READY_FOR_REVIEW'){throw 'migration_before_auth_gate'}
$service=$null;$stopped=$false
try{
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 $c.database=$c.noop_db
 $service=Start-OwnedStockService $c $pkg 'auth-startup01';[void](Wait-OwnedStockService $service)
 $before=State $c.noop_db 'auth-before-login' $c.migration_capture
 if($before.sha256 -cne $noop.post.sha256){throw 'ready_copy_changed_before_login'}
 $catalogBefore=State $c.noop_db 'auth-catalog-pre' $c.migration_catalog
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.auth_probe,$PhaseConfig,'login') $c.workspace $out 'auth-login' @{} 30 1MB)
 $afterLogin=State $c.noop_db 'auth-after-login' $c.migration_capture
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.auth_probe,$PhaseConfig,'open') $c.workspace $out 'auth-open' @{} 30 1MB)
 $afterOpen=State $c.noop_db 'auth-after-open' $c.migration_capture
 $catalogAfter=State $c.noop_db 'auth-catalog-post' $c.migration_catalog
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.auth_compare,(Join-Path $out 'auth-before-login.stdout'),(Join-Path $out 'auth-after-login.stdout'),(Join-Path $out 'auth-after-open.stdout'),(Join-Path $out 'auth-login-http.json'),(Join-Path $out 'auth-open-http.json'),(Join-Path $out 'auth-delta-private.json')) $c.workspace $out 'auth-delta-compare' @{} 30 1MB)
 $comparison=Get-Content (Join-Path $out 'auth-delta-compare.stdout') -Raw|ConvertFrom-Json
 if($comparison.status -cne 'FINITE_COMPLETE_AUTH_DELTA_VERIFIED' -or $catalogBefore.sha256 -cne $catalogAfter.sha256){throw 'auth_whole_delta_or_catalog_failed'}
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $out 'auth-delta-result.json') @{status='FINITE_AUTH_DELTA_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW';pre=$before;login_post=$afterLogin;open_post=$afterOpen;catalog_pre=$catalogBefore;catalog_post=$catalogAfter;comparison=$comparison;limits=@('Two finite login/project-open operations on new restored ready schema; not migrated full historical Auth/RBAC acceptance','Session expiry derived from original source PRE and actual bounded HTTP interval; random token/cookie remain private','No browser/Datastar or whole R3 acceptance')}
}finally{
 $secret=$null;$admin=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
