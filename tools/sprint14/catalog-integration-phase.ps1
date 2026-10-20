param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY current catalog/Auth lifecycle, retention, restart and wholeDB restore.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'catalog_integration_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'catalog_integration_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's14-catalog-integration-runtime' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'catalog_integration_finite_scope'}
if($c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'){throw 'catalog_integration_existing_candidate_only'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$names=@($c.source_db,$c.restore_db,$c.verify_db,$c.recovery_db)
foreach($db in $names){if($db -cnotmatch '^pi_restore_s14_[a-z0-9_]{1,35}$'){throw 'catalog_integration_new_database'}}
if(@($names|Select-Object -Unique).Count -ne 4){throw 'catalog_integration_distinct_databases'}
$credentialPath=Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint13/root/small-seed02/small-credentials-private.json')
if((Get-OwnedCanonicalPath $c.credentials.path) -cne $credentialPath){throw 'catalog_integration_exact_credentials_input'}
Assert-OwnedNoReparse $credentialPath;Assert-OwnedHash $credentialPath $c.credentials.sha256
# Closed S13 credentials are a read-only exception, not S14 runtime resources.
$acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new((Split-Path -Parent $credentialPath)));$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or !$acl.AreAccessRulesProtected -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or (Get-Item $credentialPath).Length -gt 64KB){throw 'catalog_integration_closed_credentials_ACL'}
if($c.small_archive_sha -cne 'A18E0BF2E061B350B0918D9116BBC4F7C0E46EE8F28FDF0C7FA342BA725A030C' -or $c.small_manifest_sha -cne '0F21A1FBDBFACCF03C7C666ABF977B0605A6EA7704BDE1D3D1A5EF52846EDACA'){throw 'catalog_integration_exact_seed02'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.small_archive,$c.small_archive_sha),@(($c.small_archive+'.manifest.json'),$c.small_manifest_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.node,$c.node_sha),@($c.probe,$c.probe_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.probe) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'catalog-integration-probe.cjs')) -or (Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'catalog_integration_source_paths'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 512MB -or $c.phase_reservation_bytes -gt 2GB){throw 'catalog_integration_resource_freeze'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.version -cne '0.7.3' -or $m.source_commit -cne $c.source_commit){throw 'catalog_integration_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$runtime=$null;$runtimeClosed=$false;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'catalog_integration_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('catalog_integration_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB){
 if($Db -cnotin ($names+@('postgres'))){throw 'catalog_integration_SQL_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Db)+$Arguments
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([string]$Db,[string]$Label,[bool]$Catalog=$false){Budget 8MB;$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'catalog_integration_full_state_or_catalog_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress));[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180)}
function URL([string]$Db,[string]$User='pi_admin'){$pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5475 user=$User password=$pw dbname=$Db connect_timeout=5 application_name=s14_catalog_integration"}
function StopRuntime{
 if(!$runtime -or $runtimeClosed){return};if($runtime.Process.HasExited){throw 'catalog_integration_unexpected_app_exit'}
 $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id)
 if(!$again -or $again.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'catalog_integration_retained_app_identity'}
 $runtime.Process.Kill();if(!$runtime.Process.WaitForExit(10000)){throw 'catalog_integration_app_stop'};$r=Complete-OwnedCapturedProcess $runtime;$script:runtimeClosed=$true
 Write-OwnedJson (Join-Path $out ($runtimeLabel+'-controlled-stop.json')) @{native=$r;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(!$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_integration_app_streams_or_listener'}
}
function StartCatalogRuntime([string]$Db,[string]$Label,$Expected){
 if($Db -cnotin @($c.restore_db,$c.recovery_db) -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_runtime_new_target_listener'}
 $script:runtimeLabel=$Label;$script:runtimeClosed=$false;Budget 8MB
 $script:runtime=Start-OwnedCapturedProcess -Program $app -ProgramSha256 $c.app_sha -Arguments @() -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=(URL $Db 'pi_app');PORT='3098';RUST_LOG='info'}
 $script:creation=$runtime.Process.StartTime.ToUniversalTime().ToString('o');$until=[DateTime]::UtcNow.AddSeconds(30)
 do{Budget;if($runtime.Process.HasExited -or [DateTime]::UtcNow -ge $until){throw 'catalog_app_not_ready'};$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue);if($listeners.Count){if(@($listeners|Where-Object {$_.OwningProcess -ne $runtime.Process.Id -or $_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'catalog_listener_identity'};break};Start-Sleep -Milliseconds 100}while($true)
 $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id);$pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$native -or $native.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation -or !$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'catalog_actual_native_identity'}
 if(!$script:readyRequested){Wait-OwnedReadyJob @(@{name='app';pid=$runtime.Process.Id;creation_utc=$native.CreationDate.ToUniversalTime().ToString('o')},@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out;$script:readyRequested=$true}
 $before=State $Db ($Label+'-before-login');EqualState $Expected $before
 $admission=Join-Path $out ($Label+'-admission.json');Write-OwnedJson $admission @{scope='S14_NEW_CATALOG_INTEGRATION_RUNTIME';database=$Db;app_port=3098;pg_port=5475;version='0.7.3';app_sha256=$c.app_sha;app_pid=$runtime.Process.Id;native_creation=$creation;cim_creation=$native.CreationDate.ToUniversalTime().ToString('o');outer_first_ready_sha256=Get-OwnedHash (Join-Path $out 'ready-response.json');startup_full_unchanged=$true;job_basis='Initial app+PG actual outer-ready; subsequent retained children inherit same admitted no-breakaway waiting worker Job. No separate direct outer Job.Member claim'}
 return @{before=$before;admission=@{path=$admission;sha256=Get-OwnedHash $admission}}
}
function RunCatalogProbe([string]$Run,[string]$Mode,[string]$Db,$Admission){
 $probe=@{scope='s14-new-small-catalog-integration';mode=$Mode;run=$Run;database=$Db;app_port=3098;pg_port=5475;output_directory=$out;deadline_utc=$c.deadline_utc;before=$Admission.before;credentials=$c.credentials;runtime_admission=$Admission.admission;http_client_sha=$c.http_client_sha;deleted_projects=@($script:deletedProjectIds)}
 $pc=Join-Path $out ($Run+'-probe-config.json');Write-OwnedJson $pc $probe
 [void](Native -Label ($Run+'-http-probe') -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$pc) -Environment @{PI_CATALOG_INTEGRATION_CONFIG_SHA=(Get-OwnedHash $pc).ToLowerInvariant()} -Seconds 680 -Cap 1MB)
 $summary=Get-Content (Join-Path $out ($Run+'-summary.json')) -Raw|ConvertFrom-Json
 if($summary.status -cne 'FINITE_CATALOG_INTEGRATION_HTTP_CAPTURED_PENDING_COMPLETE_DELTA_AND_QA_TD' -or ($Mode -ceq 'exercise' -and (!$summary.retention_512_513 -or $summary.deleted_assigned_projects -ne 1))){throw 'catalog_probe_required_result'}
 StopRuntime
 [void](Sql 'postgres' ($Run+'-app-backends-gone') @('-c',("SELECT count(*) FROM pg_stat_activity WHERE datname='"+$Db+"' AND backend_type='client backend';")) 1MB)
 if((Get-Content (Join-Path $out ($Run+'-app-backends-gone.stdout')) -Raw).Trim() -cne '0'){throw 'catalog_app_backend_remains'}
 $after=State $Db ($Run+'-after');$expected=Join-Path $out ($Run+'-expected-auth-private.json');$probe.mode='delta';$probe.after=$after;$probe.expected=@{path=$expected;sha256=Get-OwnedHash $expected};$dc=Join-Path $out ($Run+'-delta-config.json');Write-OwnedJson $dc $probe
 [void](Native -Label ($Run+'-exact-delta') -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$dc) -Environment @{PI_CATALOG_INTEGRATION_CONFIG_SHA=(Get-OwnedHash $dc).ToLowerInvariant()} -Seconds 60 -Cap 1MB)
 $delta=Get-Content (Join-Path $out ($Run+'-delta.json')) -Raw|ConvertFrom-Json
 if($delta.status -cne 'EXACT_COMPLETE_SMALL_AUTH_SESSION_CATALOG_AUDIT_AND_ALLOWED_PROJECT_REMOVAL_PENDING_QA_TD' -or !$delta.all_other_raw_rows_equal){throw 'catalog_exact_complete_delta_required'}
 return $after
}
$script:readyRequested=$false;$script:deletedProjectIds=@()
try{
 $service=Start-OwnedStockService $c $pkg 'catalog-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres')
 if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'catalog_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'catalog_bootstrap_stop'}
 Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{pid=$boot[0].Process.Id;native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_bootstrap_listener'}
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'catalog_private_port'}
 foreach($pair in @(@('source',$c.source_db),@('runtime',$c.restore_db),@('verification',$c.verify_db),@('recovery',$c.recovery_db))){$label='absent-'+$pair[0];[void](Sql 'postgres' $label @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$pair[1]+"');")));if((Get-Content (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'catalog_database_not_new'}}
 $seed=Join-Path $pkg '.local/catalog-small.dump';[IO.File]::Copy($c.small_archive,$seed,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 Stock 'restore-source' @{Mode='Restore';Database=$sm.database;TargetDatabase=$c.source_db;BackupFile=$seed}
 $original=Join-Path $pkg '.local/catalog-source.dump';Stock 'backup-source' @{Mode='Backup';Database=$c.source_db;BackupFile=$original};Stock 'restore-runtime' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.restore_db;BackupFile=$original}
 $sourcePre=State $c.source_db 'source-pre';$runtimePre=State $c.restore_db 'runtime-pre';EqualState $sourcePre $runtimePre
 $catalogPre=State $c.source_db 'source-catalog-pre' $true;$runtimeCatalogPre=State $c.restore_db 'runtime-catalog-pre' $true;EqualState $catalogPre $runtimeCatalogPre
 $a=StartCatalogRuntime $c.restore_db 'exercise-app' $runtimePre;$exerciseAfter=RunCatalogProbe 'exercise' 'exercise' $c.restore_db $a
 $exerciseModel=Get-Content (Join-Path $out 'exercise-expected-auth-private.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String;$script:deletedProjectIds=@($exerciseModel.deleted_projects)
 $a=StartCatalogRuntime $c.restore_db 'restart-app' $exerciseAfter;$restartAfter=RunCatalogProbe 'restart' 'recovery' $c.restore_db $a
 $archive=Join-Path $pkg '.local/catalog-integrated.dump';Stock 'backup-integrated' @{Mode='Backup';Database=$c.restore_db;BackupFile=$archive}
 $manifest=Get-Content ($archive+'.manifest.json') -Raw|ConvertFrom-Json
 if($manifest.database -cne $c.restore_db -or !$manifest.includes_auth -or $manifest.sha256.ToUpperInvariant() -cne (Get-OwnedHash $archive) -or $manifest.size -ne (Get-Item $archive).Length){throw 'catalog_truthful_backup'}
 Stock 'restore-untouched-verification' @{Mode='Restore';Database=$c.restore_db;TargetDatabase=$c.verify_db;BackupFile=$archive};Stock 'restore-separate-runtime' @{Mode='Restore';Database=$c.restore_db;TargetDatabase=$c.recovery_db;BackupFile=$archive}
 $verifyPre=State $c.verify_db 'verification-pre';$recoveryPre=State $c.recovery_db 'recovery-pre';EqualState $restartAfter $verifyPre;EqualState $restartAfter $recoveryPre
 $a=StartCatalogRuntime $c.recovery_db 'restored-app' $recoveryPre;$recoveredAfter=RunCatalogProbe 'restored' 'recovery' $c.recovery_db $a
 $sourceAfter=State $c.source_db 'source-after';$runtimeAfter=State $c.restore_db 'runtime-after';$verifyAfter=State $c.verify_db 'verification-after';EqualState $sourcePre $sourceAfter;EqualState $restartAfter $runtimeAfter;EqualState $verifyPre $verifyAfter
 foreach($pair in @(@('source',$c.source_db),@('runtime',$c.restore_db),@('verification',$c.verify_db),@('recovery',$c.recovery_db))){$cat=State $pair[1] ($pair[0]+'-catalog-after') $true;EqualState $catalogPre $cat}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Budget
 Write-OwnedJson (Join-Path $out 'catalog-integration-result.json') @{status='FINITE_CURRENT_CATALOG_AUTH_LIFECYCLE_RETENTION_AND_RESTORE_PENDING_QA_TD';source_pre=$sourcePre;source_after=$sourceAfter;runtime_pre=$runtimePre;exercise_after=$exerciseAfter;restart_after=$restartAfter;verification_pre=$verifyPre;verification_after=$verifyAfter;recovery_pre=$recoveryPre;recovery_after=$recoveredAfter;archive_sha256=Get-OwnedHash $archive;manifest_sha256=Get-OwnedHash ($archive+'.manifest.json');limits=@('Fresh synthetic SmallS only, not historical/R3 release acceptance','Editor ownfolder positive, Viewer/foreign refusal, assigned project archive/restore/delete with exact complete Auth/session/audit/catalog replay','Mixed real catalog/project HTTP producers through exact512/513, not30 newly executed actionfamilies','Restart plus maintained wholeDB backup/newuntouched verification/newruntime restore; each newlogin delta explicit','True concurrent CAS/demotion, browser, repository writes/jobs/projectbackup import isolation remain independent requirements')};$success=$true
}finally{try{if($runtime -and !$runtimeClosed){StopRuntime}}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}}
if(!$success){throw 'catalog_integration_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
# SOURCE ONLY: no native/HTTP/SQL execution during drafting. Exact config/resource/
# source closure/outer Job ABI and independent Root/QA/TD reviews required first.
