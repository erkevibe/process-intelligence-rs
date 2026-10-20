param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY current catalog/Auth lifecycle, retention, restart and wholeDB restore.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'catalog_import_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'catalog_import_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's14-catalog-import-runtime' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'catalog_import_finite_scope'}
if($c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'){throw 'catalog_import_existing_candidate_only'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$names=@($c.source_db,$c.restore_db,$c.verify_db)
foreach($db in $names){if($db -cnotmatch '^pi_restore_s14_[a-z0-9_]{1,35}$'){throw 'catalog_import_new_database'}}
if(@($names|Select-Object -Unique).Count -ne 3){throw 'catalog_import_distinct_databases'}
$credentialPath=Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint13/root/small-seed02/small-credentials-private.json')
if((Get-OwnedCanonicalPath $c.credentials.path) -cne $credentialPath){throw 'catalog_import_exact_credentials_input'}
Assert-OwnedNoReparse $credentialPath;Assert-OwnedHash $credentialPath $c.credentials.sha256
# Closed S13 credentials are a read-only exception, not S14 runtime resources.
$acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new((Split-Path -Parent $credentialPath)));$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or !$acl.AreAccessRulesProtected -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or (Get-Item $credentialPath).Length -gt 64KB){throw 'catalog_import_closed_credentials_ACL'}
if($c.small_archive_sha -cne 'A18E0BF2E061B350B0918D9116BBC4F7C0E46EE8F28FDF0C7FA342BA725A030C' -or $c.small_manifest_sha -cne '0F21A1FBDBFACCF03C7C666ABF977B0605A6EA7704BDE1D3D1A5EF52846EDACA'){throw 'catalog_import_exact_seed02'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.small_archive,$c.small_archive_sha),@(($c.small_archive+'.manifest.json'),$c.small_manifest_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.node,$c.node_sha),@($c.probe,$c.probe_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.probe) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'catalog-import-probe.cjs')) -or (Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'catalog_import_source_paths'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 512MB -or $c.phase_reservation_bytes -gt 2GB){throw 'catalog_import_resource_freeze'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.version -cne '0.7.3' -or $m.source_commit -cne $c.source_commit){throw 'catalog_import_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$runtime=$null;$runtimeClosed=$false;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'catalog_import_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('catalog_import_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB){
 if($Db -cnotin ($names+@('postgres'))){throw 'catalog_import_SQL_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Db)+$Arguments
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([string]$Db,[string]$Label,[bool]$Catalog=$false){Budget 8MB;$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'catalog_import_full_state_or_catalog_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress));[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180)}
function URL([string]$Db,[string]$User='pi_admin'){$pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5475 user=$User password=$pw dbname=$Db connect_timeout=5 application_name=s14_catalog_import"}
function StopRuntime{
 if(!$runtime -or $runtimeClosed){return};if($runtime.Process.HasExited){throw 'catalog_import_unexpected_app_exit'}
 $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id)
 if(!$again -or $again.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'catalog_import_retained_app_identity'}
 $runtime.Process.Kill();if(!$runtime.Process.WaitForExit(10000)){throw 'catalog_import_app_stop'};$r=Complete-OwnedCapturedProcess $runtime;$script:runtimeClosed=$true
 Write-OwnedJson (Join-Path $out ($runtimeLabel+'-controlled-stop.json')) @{native=$r;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(!$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_import_app_streams_or_listener'}
}
function StartCatalogRuntime([string]$Db,[string]$Label,$Expected){
 if($Db -cnotin @($c.restore_db) -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_runtime_new_target_listener'}
 $script:runtimeLabel=$Label;$script:runtimeClosed=$false;Budget 8MB
 $script:runtime=Start-OwnedCapturedProcess -Program $app -ProgramSha256 $c.app_sha -Arguments @() -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=(URL $Db 'pi_app');PORT='3098';RUST_LOG='info'}
 $script:creation=$runtime.Process.StartTime.ToUniversalTime().ToString('o');$until=[DateTime]::UtcNow.AddSeconds(30)
 do{Budget;if($runtime.Process.HasExited -or [DateTime]::UtcNow -ge $until){throw 'catalog_app_not_ready'};$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue);if($listeners.Count){if(@($listeners|Where-Object {$_.OwningProcess -ne $runtime.Process.Id -or $_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'catalog_listener_identity'};break};Start-Sleep -Milliseconds 100}while($true)
 $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id);$pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$native -or $native.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation -or !$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'catalog_actual_native_identity'}
 if(!$script:readyRequested){Wait-OwnedReadyJob @(@{name='app';pid=$runtime.Process.Id;creation_utc=$native.CreationDate.ToUniversalTime().ToString('o')},@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out;$script:readyRequested=$true}
 $before=State $Db ($Label+'-before-login');EqualState $Expected $before
 $admission=Join-Path $out ($Label+'-admission.json');Write-OwnedJson $admission @{scope='S14_NEW_CATALOG_IMPORT_RUNTIME';database=$Db;app_port=3098;pg_port=5475;version='0.7.3';app_sha256=$c.app_sha;app_pid=$runtime.Process.Id;native_creation=$creation;cim_creation=$native.CreationDate.ToUniversalTime().ToString('o');outer_first_ready_sha256=Get-OwnedHash (Join-Path $out 'ready-response.json');startup_full_unchanged=$true;job_basis='Initial app+PG actual outer-ready; subsequent retained children inherit same admitted no-breakaway waiting worker Job. No separate direct outer Job.Member claim'}
 return @{before=$before;admission=@{path=$admission;sha256=Get-OwnedHash $admission}}
}
function RunImportProbe($Admission){
 $probe=@{scope='s14-new-small-catalog-import';mode='exercise';run='import';database=$c.restore_db;app_port=3098;pg_port=5475;output_directory=$out;deadline_utc=$c.deadline_utc;before=$Admission.before;credentials=$c.credentials;runtime_admission=$Admission.admission;http_client_sha=$c.http_client_sha;deleted_projects=@()}
 $pc=Join-Path $out 'import-probe-config.json';Write-OwnedJson $pc $probe
 [void](Native -Label 'import-http-probe' -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$pc) -Environment @{PI_CATALOG_IMPORT_CONFIG_SHA=(Get-OwnedHash $pc).ToLowerInvariant()} -Seconds 320 -Cap 1MB)
 $summary=Get-Content (Join-Path $out 'import-summary.json') -Raw|ConvertFrom-Json
 if($summary.status -cne 'PROJECT_BACKUP_NORMAL_HTTP_ISOLATION_AND_UNVERIFIED_TRUST_PENDING_FULL_DELTA_QA_TD' -or !$summary.owner_only -or !$summary.no_imported_project_list_assignment -or !$summary.no_legacy_or_marker_created -or $summary.imported_audit_retained -le 0 -or $summary.new_records -lt 5){throw 'catalog_import_actual_isolation_coverage'}
 StopRuntime
 [void](Sql 'postgres' 'import-app-backends-gone' @('-c',("SELECT count(*) FROM pg_stat_activity WHERE datname='"+$c.restore_db+"' AND backend_type='client backend';")) 1MB)
 if((Get-Content (Join-Path $out 'import-app-backends-gone.stdout') -Raw).Trim() -cne '0'){throw 'catalog_import_backend_remains'}
 $after=State $c.restore_db 'import-after';$expected=Join-Path $out 'import-expected-auth-private.json';$probe.mode='delta';$probe.after=$after;$probe.expected=@{path=$expected;sha256=Get-OwnedHash $expected};$dc=Join-Path $out 'import-delta-config.json';Write-OwnedJson $dc $probe
 [void](Native -Label 'import-exact-delta' -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$dc) -Environment @{PI_CATALOG_IMPORT_CONFIG_SHA=(Get-OwnedHash $dc).ToLowerInvariant()} -Seconds 60 -Cap 1MB)
 $delta=Get-Content (Join-Path $out 'import-delta.json') -Raw|ConvertFrom-Json
 if($delta.status -cne 'EXACT_COMPLETE_SMALL_AUTH_SESSION_CATALOG_AUDIT_AND_ALLOWED_PROJECT_REMOVAL_PENDING_QA_TD' -or !$delta.all_other_raw_rows_equal -or $delta.deleted_projects -ne 0){throw 'catalog_import_complete_delta_required'}
 return @{after=$after;summary=$summary;delta=$delta}
}
$script:readyRequested=$false
try{
 $service=Start-OwnedStockService $c $pkg 'import-stock';[void](Wait-OwnedStockService $service);$boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres')
 if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'catalog_import_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'catalog_import_bootstrap_stop'};Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_import_bootstrap_listener'}
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'catalog_import_private_port'}
 foreach($pair in @(@('source',$c.source_db),@('runtime',$c.restore_db),@('verification',$c.verify_db))){$label='absent-'+$pair[0];[void](Sql 'postgres' $label @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$pair[1]+"');")));if((Get-Content (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'catalog_import_database_not_new'}}
 $seed=Join-Path $pkg '.local/import-small.dump';[IO.File]::Copy($c.small_archive,$seed,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 Stock 'restore-source' @{Mode='Restore';Database=$sm.database;TargetDatabase=$c.source_db;BackupFile=$seed};$archive=Join-Path $pkg '.local/import-source.dump';Stock 'backup-source' @{Mode='Backup';Database=$c.source_db;BackupFile=$archive}
 Stock 'restore-runtime' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.restore_db;BackupFile=$archive};Stock 'restore-verification' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.verify_db;BackupFile=$archive}
 $sourcePre=State $c.source_db 'source-pre';$runtimePre=State $c.restore_db 'runtime-pre';$verifyPre=State $c.verify_db 'verification-pre';EqualState $sourcePre $runtimePre;EqualState $sourcePre $verifyPre;$catalogPre=State $c.source_db 'catalog-pre' $true
 $admission=StartCatalogRuntime $c.restore_db 'import-app' $runtimePre;$actual=RunImportProbe $admission
 $sourceAfter=State $c.source_db 'source-after';$verifyAfter=State $c.verify_db 'verification-after';EqualState $sourcePre $sourceAfter;EqualState $verifyPre $verifyAfter
 foreach($pair in @(@('source',$c.source_db),@('runtime',$c.restore_db),@('verification',$c.verify_db))){$cat=State $pair[1] ($pair[0]+'-catalog-after') $true;EqualState $catalogPre $cat}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Budget
 Write-OwnedJson (Join-Path $out 'catalog-import-result.json') @{status='NORMAL_PROJECT_BACKUP_IMPORT_FULL_ISOLATION_EVIDENCE_PENDING_QA_TD';source_pre=$sourcePre;source_after=$sourceAfter;verification_pre=$verifyPre;verification_after=$verifyAfter;runtime_pre=$runtimePre;runtime_after=$actual.after;http=$actual.summary;complete_delta=$actual.delta;limits=@('Fresh maintained SmallS only, not historical release credit','Normal GET backup + multipart POST restore with exact fullpayload/rawRustJSON digest','Source workspace listfolder/placement preserved; imported project Owner-only and Root/unassigned','Imported repository folder/history preserved but every imported audit event explicitly project_backup_unverified without policy/outcome','Only new normalized header+records permitted, no new legacyKV/marker; allother rows/ledger/sequence/catalog exact','No browser hold or manualAuth delta; separate Root-owned browser phase required')};$success=$true
}finally{try{if($runtime -and !$runtimeClosed){StopRuntime}}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}}
if(!$success){throw 'catalog_import_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
# SOURCE ONLY; exact Root/QA/TD source/resource profile must be reviewed before execution.