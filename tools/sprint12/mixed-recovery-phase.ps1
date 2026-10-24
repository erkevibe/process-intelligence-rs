param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
if($c.app_port -ne 3096 -or $c.pg_port -ne 5464 -or $c.database -cne 'process_intelligence' -or $c.verification_db -cnotmatch '^pi_restore_s12_[a-z0-9_]{1,35}$' -or $c.recovery_db -cnotmatch '^pi_restore_s12_[a-z0-9_]{1,35}$' -or $c.verification_db -ceq $c.recovery_db){throw 'mixed_recovery_scope'}
Test-OwnedPackageTree $c.package $c.manifest_sha $true
$pkg=$c.package;$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $pkg 'startup01';[void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json -DateKind String
 $psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe'
 $connection=@('-h','127.0.0.1','-p','5464','-U','pi_admin','-w');$admin=@{PGPASSWORD=$secret.admin_password}
 function Capture([string]$Database,[string]$Label,[string]$Sql){
  return Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Database,'-At','-v','ON_ERROR_STOP=1','-f',$Sql)) $pkg $out $Label $admin 60 16MB
 }
 function Invoke-MixedStateComparison([string]$Left,[string]$Right,[string]$Mode,[string]$Label){
  [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.state_compare,(Join-Path $out ($Left+'.stdout')),(Join-Path $out ($Right+'.stdout')),$Mode) $c.workspace $out $Label @{} 30 1MB)
  $proof=Get-Content (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json -DateKind String
  if($proof.status -cne 'STOCK_NAMED_COMPARISON_PASSED'){throw 'mixed_recovery_comparison'}
 }
 function Probe([string]$Round){[void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$PhaseConfig,$Round) $c.workspace $out ($Round+'-http') @{} 90 1MB)}
 [void](Capture $c.database 'baseline-pre' $c.capture_sql)
 [void](Capture $c.database 'catalog-pre' $c.catalog_sql)
 Probe 'baseline'
 [void](Capture $c.database 'baseline-post' $c.capture_sql)
 Invoke-MixedStateComparison 'baseline-pre' 'baseline-post' 'exact' 'compare-baseline-readonly'
 $backup=Join-Path $pkg 'tools/database-backup.ps1';$archive=Join-Path $pkg '.local/sprint12-mixed-recovery.dump'
 if(Test-Path -LiteralPath $archive){throw 'mixed_backup_path_exists'}
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Backup','-Database',$c.database,'-BackupFile',$archive) $pkg $out 'backup' @{} 180)
 foreach($pair in @(@($c.verification_db,'verification'),@($c.recovery_db,'recovery'))){
  [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-BackupFile',$archive,'-TargetDatabase',$pair[0]) $pkg $out ('restore-'+$pair[1]) @{} 180)
  [void](Capture $pair[0] ($pair[1]+'-full') $c.capture_sql)
  Invoke-MixedStateComparison 'baseline-pre' ($pair[1]+'-full') 'restore' ('compare-'+$pair[1])
 }
 Stop-OwnedStockService $service 'fault-injection';$stopped=$true
 $service=Start-OwnedStockService $c $pkg 'startup02';$stopped=$false;[void](Wait-OwnedStockService $service)
 [void](Capture $c.database 'restart-pre' $c.capture_sql)
 Invoke-MixedStateComparison 'baseline-pre' 'restart-pre' 'crash' 'compare-crash'
 [void](Capture $c.database 'catalog-after' $c.catalog_sql)
 if((Get-OwnedHash (Join-Path $out 'catalog-pre.stdout')) -cne (Get-OwnedHash (Join-Path $out 'catalog-after.stdout'))){throw 'mixed_catalog_changed'}
 Probe 'restart'
 [void](Capture $c.database 'restart-post' $c.capture_sql)
 Invoke-MixedStateComparison 'restart-pre' 'restart-post' 'exact' 'compare-restart-readonly'
 [void](Capture $c.verification_db 'verification-after' $c.capture_sql)
 Invoke-MixedStateComparison 'verification-full' 'verification-after' 'exact' 'compare-verification-untouched01'
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 $c.database=$c.recovery_db
 $service=Start-OwnedStockService $c $pkg 'recovery-startup01';$stopped=$false;[void](Wait-OwnedStockService $service)
 [void](Capture $c.recovery_db 'recovery-pre' $c.capture_sql)
 Invoke-MixedStateComparison 'recovery-full' 'recovery-pre' 'exact' 'compare-recovery-startup'
 Probe 'recovery'
 [void](Capture $c.recovery_db 'recovery-post' $c.capture_sql)
 Invoke-MixedStateComparison 'recovery-pre' 'recovery-post' 'exact' 'compare-recovery-readonly'
 [void](Capture $c.verification_db 'verification-final' $c.capture_sql)
 Invoke-MixedStateComparison 'verification-full' 'verification-final' 'exact' 'compare-verification-untouched02'
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $out 'mixed-recovery-result.json') @{status='MIXED_BACKUP_CRASH_RECOVERY_READY_FOR_REVIEW';verification_db=$c.verification_db;recovery_db=$c.recovery_db;verification_never_app_or_login=$true;recovery_existing_cookie_no_login=$true;backup_sha256=Get-OwnedHash $archive;limits=@('Same-host controlled crash only; no infrastructure HA','Explicit named sequence transformations; no physical cluster equality','Four read-only exports per round; no browser interaction claim')}
}finally{
 $secret=$null;$admin=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
