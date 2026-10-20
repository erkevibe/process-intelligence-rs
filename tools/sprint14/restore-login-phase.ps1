param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY C08 legitimate login changes NEW restore; all evidence pending independent review.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'restore_login_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'restore_login_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's14-restore-login-refusal' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'restore_login_finite_scope'}
if($c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'){throw 'restore_login_existing_candidate_only'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$names=@($c.source_db,$c.restore_db)
foreach($db in $names){if($db -cnotmatch '^pi_restore_s14_[a-z0-9_]{1,35}$'){throw 'restore_login_new_database'}}
if($names[0] -ceq $names[1]){throw 'restore_login_distinct_databases'}
$credentialPath=Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint13/root/small-seed02/small-credentials-private.json')
if((Get-OwnedCanonicalPath $c.credentials.path) -cne $credentialPath){throw 'restore_login_exact_credentials_input'}
Assert-OwnedNoReparse $credentialPath;Assert-OwnedHash $credentialPath $c.credentials.sha256
# Closed S13 credentials are a read-only exception, not S14 runtime resources.
$acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new((Split-Path -Parent $credentialPath)));$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or !$acl.AreAccessRulesProtected -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or (Get-Item $credentialPath).Length -gt 64KB){throw 'restore_login_closed_credentials_ACL'}
if($c.small_archive_sha -cne 'A18E0BF2E061B350B0918D9116BBC4F7C0E46EE8F28FDF0C7FA342BA725A030C' -or $c.small_manifest_sha -cne '0F21A1FBDBFACCF03C7C666ABF977B0605A6EA7704BDE1D3D1A5EF52846EDACA'){throw 'restore_login_exact_seed02'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.small_archive,$c.small_archive_sha),@(($c.small_archive+'.manifest.json'),$c.small_manifest_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.node,$c.node_sha),@($c.probe,$c.probe_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.probe) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'restore-login-probe.cjs')) -or (Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'restore_login_source_paths'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 512MB -or $c.phase_reservation_bytes -gt 2GB){throw 'restore_login_resource_freeze'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.version -cne '0.7.3' -or $m.source_commit -cne $c.source_commit){throw 'restore_login_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$runtime=$null;$runtimeClosed=$false;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'restore_login_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('restore_login_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB){
 if($Db -cnotin ($names+@('postgres'))){throw 'restore_login_SQL_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Db)+$Arguments
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([string]$Db,[string]$Label,[bool]$Catalog=$false){Budget 8MB;$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'restore_login_full_state_or_catalog_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress));[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180)}
function URL([string]$Db,[string]$User='pi_admin'){$pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5475 user=$User password=$pw dbname=$Db connect_timeout=5 application_name=s14_c08_restore_login"}
function Cleanup([string]$Label,[string]$Mode,[hashtable]$Environment,[int]$Exit){
 [void](Native -Label $Label -Program $app -Sha $c.app_sha -Arguments @('--cleanup-storage-'+$Mode) -Environment $Environment -Exits @($Exit) -Seconds 300 -Cap 1MB)
 $v=Get-Content (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json
 if($Exit -eq 1){if($v.outcome -cne 'cleanup_refused' -or $v.code -cne 'cleanup_changed' -or @($v.PSObject.Properties).Count -ne 3){throw 'restore_login_exact_cleanup_changed'}}elseif($v.outcome -cne 'cleanup_verified' -or $v.candidate_rows -ne 2){throw 'restore_login_initial_Verify2'};return $v
}
function StopRuntime{
 if(!$runtime -or $runtimeClosed){return};if($runtime.Process.HasExited){throw 'restore_login_unexpected_app_exit'}
 $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id)
 if(!$again -or $again.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'restore_login_retained_app_identity'}
 $runtime.Process.Kill();if(!$runtime.Process.WaitForExit(10000)){throw 'restore_login_app_stop'};$r=Complete-OwnedCapturedProcess $runtime;$script:runtimeClosed=$true
 Write-OwnedJson (Join-Path $out 'restore-app-controlled-stop.json') @{native=$r;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(!$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'restore_login_app_streams_or_listener'}
}
try{
 $service=Start-OwnedStockService $c $pkg 'restore-login-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres')
 if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'restore_login_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'restore_login_bootstrap_stop'}
 Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{pid=$boot[0].Process.Id;native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'restore_login_bootstrap_listener'}
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'restore_login_private_port'}
 foreach($db in $names){$side=if($db -ceq $c.source_db){'source'}else{'restore'};$label='absent-'+$side;[void](Sql 'postgres' $label @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$db+"');")));if((Get-Content (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'restore_login_database_not_new'}}
 $seed=Join-Path $pkg '.local/c08-small.dump';[IO.File]::Copy($c.small_archive,$seed,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 Stock 'restore-source' @{Mode='Restore';Database=$sm.database;TargetDatabase=$c.source_db;BackupFile=$seed}
 $archive=Join-Path $pkg '.local/c08-source.dump';Stock 'backup-source' @{Mode='Backup';Database=$c.source_db;BackupFile=$archive};Stock 'restore-verification' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.restore_db;BackupFile=$archive}
 $sp=State $c.source_db 'source-pre';$rp=State $c.restore_db 'restore-pre';EqualState $sp $rp
 $sc=State $c.source_db 'source-catalog-pre' $true;$rc=State $c.restore_db 'restore-catalog-pre' $true;EqualState $sc $rc
 $plan=Join-Path $pkg '.local/c08.plan.json';$receipt=Join-Path $pkg '.local/c08.receipt.json';$cli=@{PI_DATABASE_URL=URL $c.source_db;PI_CLEANUP_RESTORE_URL=URL $c.restore_db;PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan;PI_CLEANUP_RECEIPT=$receipt}
 [void](Cleanup 'initial-verify' 'verify' $cli 0);Assert-OwnedNoReparse $plan;$oldPlanHash=Get-OwnedHash $plan
 [void](Sql $c.restore_db 'restore-identity' @('-c',"SELECT jsonb_build_object('database',current_database(),'server_version_num',current_setting('server_version_num'),'encoding',current_setting('server_encoding'),'recovery',pg_is_in_recovery());"))
 $identity=Get-Content (Join-Path $out 'restore-identity.stdout') -Raw|ConvertFrom-Json
 if($identity.database -cne $c.restore_db -or $identity.server_version_num -cne '180006' -or $identity.encoding -cne 'UTF8' -or $identity.recovery){throw 'restore_login_actual_PG_identity'}
 Budget 8MB;$runtime=Start-OwnedCapturedProcess -Program $app -ProgramSha256 $c.app_sha -Arguments @() -WorkingDirectory $pkg -OutputDirectory $out -Label 'restore-app' -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=(URL $c.restore_db 'pi_app');PORT='3098';RUST_LOG='info'}
 $creation=$runtime.Process.StartTime.ToUniversalTime().ToString('o');$until=[DateTime]::UtcNow.AddSeconds(30)
 do{Budget;if($runtime.Process.HasExited -or [DateTime]::UtcNow -ge $until){throw 'restore_login_app_not_ready'};$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue);if($listeners.Count){if(@($listeners|Where-Object {$_.OwningProcess -ne $runtime.Process.Id -or $_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'restore_login_listener_identity'};break};Start-Sleep -Milliseconds 100}while($true)
 $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id);$pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$cim -or $cim.ExecutablePath -cne $app -or !$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe') -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'restore_login_native_app_PG_identity'}
 Wait-OwnedReadyJob @(@{name='app';pid=$runtime.Process.Id;creation_utc=$cim.CreationDate.ToUniversalTime().ToString('o')},@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out
 $beforeLogin=State $c.restore_db 'restore-before-login';EqualState $rp $beforeLogin
 $admission=Join-Path $out 'restore-runtime-admission.json';Write-OwnedJson $admission @{scope='S14_NEW_RESTORE_LOGIN_ONLY';database=$c.restore_db;app_port=3098;app_pid=$runtime.Process.Id;native_creation=$creation;cim_creation=$cim.CreationDate.ToUniversalTime().ToString('o');outer_ready_sha256=Get-OwnedHash (Join-Path $out 'ready-response.json');app_sha256=$c.app_sha;startup_full_unchanged=$true}
 $probe=@{scope='s14-new-verification-restore-legitimate-login';mode='login';actor='owner';app_port=3098;pg_port=5475;restore_db=$c.restore_db;output_directory=$out;deadline_utc=$c.deadline_utc;before=$beforeLogin;credentials=$c.credentials;runtime_admission=@{path=$admission;sha256=Get-OwnedHash $admission}}
 $pc=Join-Path $out 'restore-login-config.json';Write-OwnedJson $pc $probe
 [void](Native -Label 'legitimate-login-probe' -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$pc) -Environment @{PI_RESTORE_LOGIN_CONFIG_SHA=(Get-OwnedHash $pc).ToLowerInvariant()} -Seconds 40 -Cap 1MB)
 StopRuntime
 [void](Sql 'postgres' 'restore-app-backends-gone' @('-c',("SELECT count(*) FROM pg_stat_activity WHERE datname='"+$c.restore_db+"' AND backend_type='client backend';")) 1MB)
 if((Get-Content (Join-Path $out 'restore-app-backends-gone.stdout') -Raw).Trim() -cne '0'){throw 'restore_login_backend_remains'}
 $afterLogin=State $c.restore_db 'restore-after-login';$sourceAfterLogin=State $c.source_db 'source-after-login';EqualState $sp $sourceAfterLogin
 $probe.mode='delta';$probe.after=$afterLogin;$witness=Join-Path $out 'restore-login-witness-private.json';$probe.witness=@{path=$witness;sha256=Get-OwnedHash $witness}
 $dc=Join-Path $out 'restore-login-delta-config.json';Write-OwnedJson $dc $probe
 [void](Native -Label 'exact-login-delta' -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$dc) -Environment @{PI_RESTORE_LOGIN_CONFIG_SHA=(Get-OwnedHash $dc).ToLowerInvariant()} -Seconds 40 -Cap 1MB)
 $failedPlan=Join-Path $pkg '.local/c08-fresh-refused.plan.json';$fresh=@{};foreach($k in $cli.Keys){$fresh[$k]=$cli[$k]};$fresh.PI_CLEANUP_PLAN=$failedPlan
 [void](Cleanup 'changed-restore-verify-refusal' 'verify' $fresh 1);if(Test-Path $failedPlan){throw 'restore_login_refused_verify_wrote_plan'}
 Assert-OwnedHash $plan $oldPlanHash;$cli.PI_CLEANUP_CONFIRM_SHA=$oldPlanHash;[void](Cleanup 'old-plan-apply-refusal' 'apply' $cli 1)
 if(Test-Path $receipt){throw 'restore_login_refusal_wrote_receipt'};Assert-OwnedHash $plan $oldPlanHash
 $sourcePost=State $c.source_db 'source-post';$restorePost=State $c.restore_db 'restore-post';EqualState $sp $sourcePost;EqualState $afterLogin $restorePost
 $sourceCatalogPost=State $c.source_db 'source-catalog-post' $true;$restoreCatalogPost=State $c.restore_db 'restore-catalog-post' $true;EqualState $sc $sourceCatalogPost;EqualState $rc $restoreCatalogPost
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Budget
 Write-OwnedJson (Join-Path $out 'restore-login-result.json') @{status='LEGITIMATE_RESTORE_LOGIN_CHANGED_COPY_REFUSED_PENDING_QA_TD';source_pre=$sp;source_post=$sourcePost;restore_pre=$rp;restore_after_login=$afterLogin;restore_post=$restorePost;source_catalog_pre=$sc;source_catalog_post=$sourceCatalogPost;restore_catalog_pre=$rc;restore_catalog_post=$restoreCatalogPost;initial_plan_sha256=$oldPlanHash;login_delta_sha256=Get-OwnedHash (Join-Path $out 'restore-login-delta.json');refusal_code='cleanup_changed';limits=@('One actual owner login to NEW verification restore only; no reset/logout','Session/pruning/expiry/version independently replayed from complete small state, every other raw row conserved','No C18/fullhistory/R3/writeRBAC/browser acceptance','Single invocation each; no inferred automatic_retry JSON field')};$success=$true
}finally{
 try{if($runtime -and !$runtimeClosed){StopRuntime}}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}
}
if(!$success){throw 'restore_login_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
# SOURCE ONLY. No native/HTTP execution while drafting. Exact config, private output,
# current candidate/credentials pins, full capture allowlist and independently authored
# Root/QA/TD prospective reviews are mandatory before launch. Production 5/2/10 unchanged.
