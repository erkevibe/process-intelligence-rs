param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
if($c.scope -cne 'new-stock-restore-auth-owner-rename-retention' -or $c.database -cne 'process_intelligence' -or $c.pg_port -ne 5462 -or $c.app_port -ne 3095 -or $c.audit_db -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $c.verification_db -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $c.audit_db -ceq $c.verification_db){throw 'new_audit_scope'}
if([DateTime]::UtcNow -ge [DateTime]'2026-10-12T16:45:00Z' -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 6GB){throw 'audit_resource_admission'}
Import-Module $c.service_module -Force -DisableNameChecking
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $pkg 'bootstrap01';[void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 $psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe'
 $connection=@('-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_admin','-w')
 function Capture([string]$Database,[string]$Label,[string]$Sql=$c.migration_capture){
  if($Database -cnotin @($c.audit_db,$c.verification_db)){throw 'audit_read_database_scope'}
  $r=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Database,'-At','-v','ON_ERROR_STOP=1','-f',$Sql)) $pkg $out $Label $admin 60 16MB
  return @{database=$Database;sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native_exit=$r.native_exit}
 }
 function Probe([string]$Mode){
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.audit_probe,$PhaseConfig,$Mode) $c.workspace $out ('audit-http-'+$Mode) @{} 600 1MB)
 }
 function RequireEqual($Left,$Right,[string]$Reason){if($Left.sha256 -cne $Right.sha256 -or $Left.bytes -ne $Right.bytes){throw $Reason}}
 $backup=Join-Path $pkg 'tools/database-backup.ps1'
 $retainedArchive=Join-Path $pkg '.local/retained-audit-stock.dump'
 [IO.File]::Copy($c.original_archive,$retainedArchive,$false)
 Assert-OwnedHash $retainedArchive $c.original_archive_sha
 [IO.File]::Copy(($c.original_archive+'.manifest.json'),($retainedArchive+'.manifest.json'),$false)
 foreach($pair in @(@($c.audit_db,'audit'),@($c.verification_db,'verification'))){
  [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-BackupFile',$retainedArchive,'-TargetDatabase',$pair[0]) $pkg $out ('restore-'+$pair[1]) @{} 120)
 }
 $verifiedPre=Capture $c.verification_db 'verification-pre'
 $verifiedCatalogPre=Capture $c.verification_db 'verification-catalog-pre' $c.migration_catalog
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 $c.database=$c.audit_db
 $service=Start-OwnedStockService $c $pkg 'audit-startup01';$stopped=$false;[void](Wait-OwnedStockService $service)
 [IO.File]::Copy($c.seed_private,(Join-Path $out 'http-private-state.json'),$false)
 Assert-OwnedHash (Join-Path $out 'http-private-state.json') $c.seed_private_sha
 $beforeLogin=Capture $c.audit_db 'audit-before-login'
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.auth_probe,$PhaseConfig,'login') $c.workspace $out 'auth-login' @{} 30 1MB)
 $afterLogin=Capture $c.audit_db 'audit-after-login'
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.auth_probe,$PhaseConfig,'open') $c.workspace $out 'auth-open' @{} 30 1MB)
 $pre=Capture $c.audit_db 'audit-pre'
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.auth_compare,(Join-Path $out 'audit-before-login.stdout'),(Join-Path $out 'audit-after-login.stdout'),(Join-Path $out 'audit-pre.stdout'),(Join-Path $out 'auth-login-http.json'),(Join-Path $out 'auth-open-http.json'),(Join-Path $out 'auth-delta-private.json')) $c.workspace $out 'auth-delta-compare' @{} 30 1MB)
 $catalogPre=Capture $c.audit_db 'audit-catalog-pre' $c.migration_catalog
 Probe 'prepare';Probe 'at512'
 $at512=Capture $c.audit_db 'audit-at512'
 Probe 'at513'
 $at513=Capture $c.audit_db 'audit-at513'
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.audit_compare,$out) $c.workspace $out 'audit-retention-compare' @{} 60 1MB)
 $comparison=Get-Content (Join-Path $out 'audit-retention-compare.stdout') -Raw|ConvertFrom-Json
 if($comparison.status -cne 'FINITE_AUTH_OWNER_RETENTION_512_513_VERIFIED'){throw 'audit_retention_contract'}
 Probe 'negative'
 $negativePost=Capture $c.audit_db 'audit-negative-post';RequireEqual $at513 $negativePost 'audit_negative_state_changed'
 $catalogPost=Capture $c.audit_db 'audit-catalog-post' $c.migration_catalog;RequireEqual $catalogPre $catalogPost 'audit_catalog_changed'
 $verifiedMid=Capture $c.verification_db 'verification-mid';RequireEqual $verifiedPre $verifiedMid 'audit_verification_copy_changed'
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 $service=Start-OwnedStockService $c $pkg 'audit-startup02';$stopped=$false;[void](Wait-OwnedStockService $service)
 $restart=Capture $c.audit_db 'audit-restart';RequireEqual $at513 $restart 'audit_restart_whole_state_changed'
 Probe 'restart'
 $verifiedFinal=Capture $c.verification_db 'verification-final';RequireEqual $verifiedPre $verifiedFinal 'audit_verified_copy_changed_after_restart'
 $verifiedCatalogFinal=Capture $c.verification_db 'verification-catalog-final' $c.migration_catalog;RequireEqual $verifiedCatalogPre $verifiedCatalogFinal 'audit_verified_catalog_changed'
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Test-OwnedPackageTree $pkg $c.manifest_sha $true
 Write-OwnedJson (Join-Path $out 'audit-retention-result.json') @{status='FINITE_AUTH_OWNER_RETENTION_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW';comparison=$comparison;pre=$pre;at512=$at512;at513=$at513;negative_post=$negativePost;restart=$restart;catalog_pre=$catalogPre;catalog_post=$catalogPost;verification_pre=$verifiedPre;verification_mid=$verifiedMid;verification_final=$verifiedFinal;verification_catalog_pre=$verifiedCatalogPre;verification_catalog_final=$verifiedCatalogFinal;verification_app_or_login=$false;limits=@('Actual projectrename producer in one Auth-owner audit scope only; no allproducer audit/R3 acceptance','Same-database complete raw state and restart/export comparison; no cross-database physical/OID equivalence claimed','Viewer/staleCAS refusals and viewer/foreign projections finite only, not full lifecycle/concurrency matrix','No browser/Datastar or cleanup Apply execution')}
}finally{
 $secret=$null;$admin=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
