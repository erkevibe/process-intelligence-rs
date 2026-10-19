param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
if($c.app_port -ne 3095 -or $c.pg_port -ne 5462 -or $c.database -cne 'process_intelligence' -or $c.verification_db -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $c.recovery_db -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $c.verification_db -ceq $c.recovery_db){throw 'stock_new_scope'}
if([DateTime]::UtcNow -ge [DateTime]'2026-10-12T16:45:00Z' -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 6GB){throw 'stock_phase_admission'}
Assert-OwnedPrivateDirectory (Split-Path -Parent $c.credentials)
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$service=$null;$stopped=$false
try{
    $service=Start-OwnedStockService $c $pkg 'startup01'
    [void](Wait-OwnedStockService $service)
    $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
    $bin=Join-Path $pkg 'runtime/postgresql/pgsql/bin';$psql=Join-Path $bin 'psql.exe'
    $connection=@('-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_admin','-w')
    $admin=@{PGPASSWORD=$secret.admin_password}
    function Capture([string]$Database,[string]$Label,[string]$Sql){
        $r=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Database,'-At','-v','ON_ERROR_STOP=1','-f',$Sql)) $pkg $out $Label $admin 60 16MB
        return @{sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native_exit=$r.native_exit;database=$Database}
    }
    function Probe([string]$Mode){
        [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.http_probe,$PhaseConfig,$Mode) $c.workspace $out ('http-'+$Mode) @{} 180 1MB)
    }
    function CompareStock([string]$Left,[string]$Right,[string]$Mode,[string]$Label){
        [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.state_compare,(Join-Path $out ($Left+'.stdout')),(Join-Path $out ($Right+'.stdout')),$Mode) $c.workspace $out $Label @{} 30 1MB)
        $proof=Get-Content (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json -DateKind String
        if($proof.status -cne 'STOCK_NAMED_COMPARISON_PASSED'){throw 'stock_comparison_result'}
        return $proof
    }
    Probe 'seed'
    $before=Capture $c.database 'negative-pre' $c.capture_sql
    $catalogBefore=Capture $c.database 'catalog-pre' $c.catalog_sql
    Probe 'negative'
    $after=Capture $c.database 'negative-post' $c.capture_sql
    if($before.sha256 -cne $after.sha256 -or $before.bytes -ne $after.bytes){throw 'stock_negative_state_changed'}
    $backup=Join-Path $pkg 'tools/database-backup.ps1';$archive=Join-Path $pkg '.local/stock-flow.dump'
    [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Backup','-Database',$c.database,'-BackupFile',$archive) $pkg $out 'stock-backup' @{} 120)
    foreach($pair in @(@($c.verification_db,'verify'),@($c.recovery_db,'recovery'))){
        [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-BackupFile',$archive,'-TargetDatabase',$pair[0]) $pkg $out ('stock-restore-'+$pair[1]) @{} 120)
    }
    $verified=Capture $c.verification_db 'verification-full' $c.capture_sql
    $recovery=Capture $c.recovery_db 'recovery-full' $c.capture_sql
    $verifyComparison=CompareStock 'negative-pre' 'verification-full' 'restore' 'compare-verification'
    $recoveryComparison=CompareStock 'negative-pre' 'recovery-full' 'restore' 'compare-recovery'
    # Deliberate app AND postmaster crash, followed by original stock startup.
    Stop-OwnedStockService $service 'fault-injection';$stopped=$true
    $service=Start-OwnedStockService $c $pkg 'startup02';$stopped=$false
    [void](Wait-OwnedStockService $service)
    $restart=Capture $c.database 'restart-before-login' $c.capture_sql
    $catalogAfter=Capture $c.database 'catalog-after' $c.catalog_sql
    $crashComparison=CompareStock 'negative-pre' 'restart-before-login' 'crash' 'compare-crash'
    if($catalogBefore.sha256 -cne $catalogAfter.sha256){throw 'stock_crash_restart_catalog'}
    Probe 'restart'
    # Verification copy is never passed to the application or any login.
    $verifiedAfter=Capture $c.verification_db 'verification-after' $c.capture_sql
    if($verified.sha256 -cne $verifiedAfter.sha256){throw 'stock_verification_copy_changed'}
    Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
    $c.database=$c.recovery_db
    $service=Start-OwnedStockService $c $pkg 'recovery-startup01';$stopped=$false
    [void](Wait-OwnedStockService $service)
    $recoveryBeforeLogin=Capture $c.recovery_db 'recovery-before-login' $c.capture_sql
    $recoveryStartupComparison=CompareStock 'recovery-full' 'recovery-before-login' 'exact' 'compare-recovery-startup'
    Probe 'recovery'
    $verifiedFinal=Capture $c.verification_db 'verification-final' $c.capture_sql
    if($verified.sha256 -cne $verifiedFinal.sha256){throw 'stock_verified_copy_changed_during_recovery'}
    Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
    Test-OwnedPackageTree $pkg $c.manifest_sha $true
    Write-OwnedJson (Join-Path $out 'stock-result.json') @{status='STOCK_FINITE_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW';negative_pre=$before;negative_post=$after;verification=$verified;recovery=$recovery;recovery_before_login=$recoveryBeforeLogin;restart_before_login=$restart;verification_after=$verifiedAfter;verification_final=$verifiedFinal;catalog_before=$catalogBefore;catalog_after=$catalogAfter;restore_comparison=$verifyComparison;recovery_comparison=$recoveryComparison;crash_comparison=$crashComparison;recovery_startup_comparison=$recoveryStartupComparison;actual_crash_injected=$true;recovery_copy_actual_login_export=$true;app_graceful_exit_claimed=$false;verified_copy_app_or_login=$false;limits=@('No Datastar/browser interaction proof','No logout/second setup refusal credit','No schema-refusal or migration rollback acceptance from successful startup','Same-host crash recovery; no infrastructure HA','Full non-sequence managed/Auth raw rows and explicit structural catalog exact; sequence transformations named, no full physical sequence equality','Cleanup/SQL5 frozen byte-exact oracle remains unchanged')}
}finally{
    $secret=$null;$admin=$null
    if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
