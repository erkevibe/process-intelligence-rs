param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY: ORIGINAL full C2 PRE runtime restoration and offline PRE recovery.
# Supersedes unexecuted POST-runtime draft4F17E636136563DD4C9A3C6C9A31C06AB5CD316CED74927F13F80CB5A2E03FD5.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'recovery_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'recovery_preimport_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-full-c2-recovery-http' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5465 -or $c.app_port -ne 3097 -or $c.database -cne 'process_intelligence' -or $c.source_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'recovery_exact_new_scope'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$privateRoot=Join-Path $workspace '.local/sprint13'
$out=Get-OwnedCanonicalPath $c.output_directory;$install=Get-OwnedCanonicalPath $c.install_parent;Assert-OwnedPrivateDirectory $out
if($out -ceq $install -or $out.StartsWith($install.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $install.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'recovery_disjoint_install_output'}
$names=@($c.runtime_db,$c.recovery_db);if($names[0] -ceq $names[1] -or @($names|Where-Object {$_ -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'}).Count){throw 'recovery_new_distinct_databases'}
function Proof($Pin){Assert-OwnedNoReparse $Pin.path;Assert-OwnedHash $Pin.path $Pin.sha256;Assert-OwnedPrivateDirectory (Split-Path -Parent $Pin.path);if((Get-Item $Pin.path).Length -gt 4MB){throw 'recovery_proof_bound'};return Get-Content $Pin.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
$full=Proof $c.full_current_proof
if($full.input_archive_sha256 -cne '3A0E6E244384D141A326345E0161AEC0AFA7EC9AF2563E9C03CBDD1B04770274'){throw 'recovery_immutable_C2_lineage'}
if($full.status -cne 'S13_FULL_C02_C14_C18_DATABASE_RESTORE_EVIDENCE_PENDING_QA_TD' -or $full.package_sha256.ToUpperInvariant() -cne $c.package_sha.ToUpperInvariant() -or $full.executable_sha256.ToUpperInvariant() -cne $c.app_sha.ToUpperInvariant() -or $full.source_commit -cne $c.source_commit -or $full.actual_source_post.sha256.ToUpperInvariant() -cne '4F3055304BF6B6B3CAFFD7C5D9EE8D7E3C021AE031B03D36B5A3981EB77DE256' -or $full.actual_source_post.bytes -ne 307159782 -or $full.empty_apply.outcome -cne 'cleanup_empty' -or $full.empty_apply.deleted_rows -ne 0 -or $full.empty_apply.database_writes -ne 0){throw 'recovery_new_actual_fullC2_success_required'}
$native=Proof $c.full_phase_native
if($native.native_exit -ne 0 -or !$native.stdout_complete -or !$native.stderr_complete -or $native.output_limit -or $native.capture_fault -or $native.drain_timeout){throw 'recovery_full_phase_native_complete'}
$backupNative=Proof $c.post_backup_native
if($backupNative.native_exit -ne 0 -or !$backupNative.stdout_complete -or !$backupNative.stderr_complete -or $backupNative.output_limit -or $backupNative.capture_fault -or $backupNative.drain_timeout){throw 'recovery_post_backup_native_complete'}
$postInput=Get-OwnedCanonicalPath $c.post_archive
if(!$postInput.StartsWith($privateRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'recovery_POST_must_be_NEW_S13_input'}
Assert-OwnedNoReparse $postInput;Assert-OwnedHash $c.post_archive $c.post_archive_sha;Assert-OwnedHash ($c.post_archive+'.manifest.json') $c.post_manifest_sha
$postManifest=Get-Content ($c.post_archive+'.manifest.json') -Raw|ConvertFrom-Json
if($postManifest.database -cne $full.actual_source_post.database -or !$postManifest.includes_auth -or $postManifest.format -cne 'postgres_custom' -or $postManifest.size -ne (Get-Item $c.post_archive).Length -or $postManifest.sha256.ToUpperInvariant() -cne $c.post_archive_sha.ToUpperInvariant()){throw 'recovery_truthful_new_POST_manifest'}
$preInput=Get-OwnedCanonicalPath $c.pre_archive
if(!$preInput.StartsWith($privateRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'recovery_PRE_must_be_NEW_S13_input'}
Assert-OwnedNoReparse $preInput;Assert-OwnedHash $preInput $c.pre_archive_sha;Assert-OwnedHash ($preInput+'.manifest.json') $c.pre_manifest_sha
$preManifest=Get-Content ($preInput+'.manifest.json') -Raw|ConvertFrom-Json
if($c.pre_archive_sha.ToUpperInvariant() -cne $full.actual_source_archive_sha256.ToUpperInvariant() -or $preManifest.database -cne $full.full_source_pre.database -or !$preManifest.includes_auth -or $preManifest.format -cne 'postgres_custom' -or $preManifest.size -ne (Get-Item $preInput).Length -or $preManifest.sha256.ToUpperInvariant() -cne $c.pre_archive_sha.ToUpperInvariant()){throw 'recovery_truthful_new_PRE_manifest'}
$original=Join-Path $workspace '.local/sprint09/qa/package-c2/process-intelligence-rs-0.7.1-windows-x86_64/.local/c2-c02-normalized01.dump'
Assert-OwnedHash $original '3A0E6E244384D141A326345E0161AEC0AFA7EC9AF2563E9C03CBDD1B04770274';Assert-OwnedHash ($original+'.manifest.json') 'BD4BC1F45EA1AEB3A8D2668C6D0E7EFF39413A98CD27FD65C4B272ED10C735D7'
$creds=Join-Path $privateRoot 'root/historical-credentials-check02/credentials-private.json'
if((Get-OwnedCanonicalPath $c.credentials_private.path) -cne (Get-OwnedCanonicalPath $creds)){throw 'recovery_literal_verified_credential_source'}
Assert-OwnedHash $creds $c.credentials_private.sha256
foreach($p in @(@($c.credential_native_record.path,(Join-Path $privateRoot 'root/historical-credentials-check02/child.process.json')),@($c.credential_result.path,(Join-Path $privateRoot 'root/historical-credentials-check02/child.stdout')))){if((Get-OwnedCanonicalPath $p[0]) -cne (Get-OwnedCanonicalPath $p[1])){throw 'recovery_literal_actual_credential_native_proofs'}}
foreach($role in @('Root','QA','TD')){$r=Proof $c.input_reviews[$role];if($r.author_role -cne $role -or $r.verdict -cne 'ACTUAL_CURRENT_FULL_C2_POST_ARCHIVE_HTTP_INPUT_GO' -or $r.full_proof_sha256.ToUpperInvariant() -cne $c.full_current_proof.sha256.ToUpperInvariant() -or $r.full_native_sha256.ToUpperInvariant() -cne $c.full_phase_native.sha256.ToUpperInvariant() -or $r.backup_native_sha256.ToUpperInvariant() -cne $c.post_backup_native.sha256.ToUpperInvariant() -or $r.post_archive_sha256.ToUpperInvariant() -cne $c.post_archive_sha.ToUpperInvariant() -or $r.post_manifest_sha256.ToUpperInvariant() -cne $c.post_manifest_sha.ToUpperInvariant() -or $r.credential_check_source_sha256 -cne $c.credential_check_source.sha256){throw 'recovery_independent_actual_input_mapping'}}
foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256}
Assert-OwnedHash $c.export_reference.path $c.export_reference.sha256
Assert-OwnedHash $c.export_reference_source.path $c.export_reference_source.sha256
$referenceBuild=Proof $c.export_reference_build
$referenceSelfTest=Proof $c.export_reference_selftest
foreach($n in @($referenceBuild,$referenceSelfTest)){if($n.native_exit -ne 0 -or !$n.stdout_complete -or !$n.stderr_complete -or $n.capture_fault -or $n.output_limit -or $n.drain_timeout){throw 'recovery_export_reference_actual_native_required'}}
if($c.export_reference.sha256 -cne '2C0139B657D3AD4A2B36D104DDD203133C8C68F801B3D4FDADB53CB66E3F2FFE' -or $c.export_reference_source.sha256 -cne 'DBF9D572DC89E71AC83BF8DF34C26A4ADB4DE8EFA16BF0C801EF946A807744CA' -or $referenceSelfTest.program_sha256 -cne $c.export_reference.sha256 -or $referenceBuild.program_sha256 -cne 'CBD682CF84CCC20BFDE002443274F9768F777B68AFEF63DA4462ABB490C0A4FF'){throw 'recovery_exact_compiled_reference_provenance'}
foreach($p in @(@($c.node,$c.node_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha),@($c.probe,$c.probe_sha),@($c.credential_check_source.path,$c.credential_check_source.sha256))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'recovery_literal_complete_catalog'}
if((Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint11/root/sql5-inputs01/capture.sql')) -or $c.capture_sql_sha -cne '054242566AC35D3AFAC986298BB030D8536A72710FA40F30ECA3193D8361A45B' -or (Get-OwnedCanonicalPath $c.probe) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'full-recovery-http-probe.cjs'))){throw 'recovery_literal_current_capture_probe'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 4000000000L -or $c.phase_reservation_bytes -gt 6GB){throw 'recovery_freeze_full_peak'}
$resourceBudget=New-S13PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S13PhaseBudget -Proof $resourceBudget -Next $Next}
if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -in @(5465,3097)).Count){throw 'recovery_new_ports_absent'}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $install $c.manifest_sha
$manifest=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($manifest.version -cne '0.7.3' -or $manifest.source_commit -cne $c.source_commit){throw 'recovery_current_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$runtime=$null;$secret=$null;$creation=$null;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=4MB){
 Budget $Cap
 $p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'recovery_owned_child_stop_deadline'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;automatic_retry=$false}
 if($forced -or $r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('recovery_native_failed_'+$Label)}
 Budget;return $r
}
function Sql([string]$Database,[string]$Label,[string[]]$Arguments,[long]$Cap=1MB){
 if($Database -cnotin ($names+@('postgres'))){throw 'recovery_owned_SQL_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-d',$Database)+$Arguments
 # Only the C2 reference snapshot reader uses fixed UTC+05; the app is unchanged.
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=Etc/GMT-5 -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([string]$Database,[string]$Label){Budget 1GB;$r=Sql $Database $Label @('-f',$c.capture_sql) 1GB;return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256;database=$Database;native_exit=$r.native_exit}}
function Catalog([string]$Database,[string]$Label){Budget 16MB;$r=Sql $Database $Label @('-f',$c.catalog_sql) 16MB;return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256;database=$Database;native_exit=$r.native_exit;sql_sha256=$c.catalog_sql_sha}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'recovery_full_state_changed'}}
function Restore([string]$Label,[string]$Archive,[string]$Db){$m=Get-Content ($Archive+'.manifest.json') -Raw|ConvertFrom-Json;[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',(@{Mode='Restore';Database=$m.database;BackupFile=$Archive;TargetDatabase=$Db}|ConvertTo-Json -Compress));[void](Native $Label $c.pwsh $c.pwsh_sha $argv @{} 180)}
try{
 $service=Start-OwnedStockService $c $pkg 'recovery-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');if($boot.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'recovery_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'recovery_bootstrap_stop'}
 Write-OwnedJson (Join-Path $out 'bootstrap-forced-stop.json') @{pid=$boot[0].Process.Id;creation=$boot[0].Creation;native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(@(Get-NetTCPConnection -LocalPort 3097 -State Listen -ErrorAction SilentlyContinue).Count){throw 'recovery_bootstrap_listener_remains'}
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5465){throw 'recovery_private_port'}
 foreach($db in $names){$label='absent-'+$db.Substring(15).Replace('_','-');[void](Sql 'postgres' $label @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$db+"');")));if((Get-Content (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'recovery_database_not_new'}}
 $post=Join-Path $pkg '.local/current-post.dump';$pre=Join-Path $pkg '.local/current-pre.dump'
 foreach($pair in @(@($c.post_archive,$post),@($preInput,$pre))){[IO.File]::Copy($pair[0],$pair[1],$false);[IO.File]::Copy(($pair[0]+'.manifest.json'),($pair[1]+'.manifest.json'),$false)}
 Restore 'restore-new-pre-runtime' $pre $c.runtime_db;Restore 'restore-new-pre-recovery' $pre $c.recovery_db
 $runtimePre=State $c.runtime_db 'runtime-restored-pre';EqualState $runtimePre $full.full_source_pre
 EqualState $runtimePre @{bytes=614304123;sha256='9959D3E9E746460C0C52853D139DCBCCFF37EE230907537AB437FCFE33933DA1'}
 $recoveryPre=State $c.recovery_db 'offline-recovery-pre';EqualState $recoveryPre @{bytes=614304123;sha256='9959D3E9E746460C0C52853D139DCBCCFF37EE230907537AB437FCFE33933DA1'}
 $runtimeCatalogPre=Catalog $c.runtime_db 'runtime-catalog-pre';$offlineCatalogPre=Catalog $c.recovery_db 'offline-catalog-pre';EqualState $runtimeCatalogPre $offlineCatalogPre
 [void](Sql $c.runtime_db 'runtime-identity' @('-c',"SELECT jsonb_build_object('database',current_database(),'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()),'system_identifier',(pg_control_system()).system_identifier::text,'server_version_num',current_setting('server_version_num'),'encoding',current_setting('server_encoding'),'recovery',pg_is_in_recovery());"))
 $identity=Get-Content (Join-Path $out 'runtime-identity.stdout') -Raw|ConvertFrom-Json;if($identity.database -cne $c.runtime_db -or $identity.server_version_num -cne '180006' -or $identity.encoding -cne 'UTF8' -or $identity.recovery){throw 'recovery_actual_PG_identity'}
 $url="host=127.0.0.1 port=5465 user=pi_app password=$($secret.app_password) dbname=$($c.runtime_db) connect_timeout=5 application_name=s13_full_recovery_http"
 $runtime=Start-OwnedCapturedProcess -Program $app -ProgramSha256 $c.app_sha -Arguments @() -WorkingDirectory $pkg -OutputDirectory $out -Label 'full-http-runtime' -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=$url;PORT='3097';RUST_LOG='info'}
 $creation=$runtime.Process.StartTime.ToUniversalTime().ToString('o');$ready=[DateTime]::UtcNow.AddSeconds(30)
 do{Budget;if($runtime.Process.HasExited -or [DateTime]::UtcNow -ge $ready){throw 'recovery_app_not_ready'};$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 3097 -ErrorAction SilentlyContinue);if($listeners.Count){if(@($listeners|Where-Object {$_.OwningProcess -ne $runtime.Process.Id -or $_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'recovery_listener_identity'};break};Start-Sleep -Milliseconds 100}while($true)
 $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id);$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($pg.Count -ne 1){throw 'recovery_PG_retained'};$pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$cim -or $cim.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation -or !$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'recovery_actual_app_PG_identity'}
 Wait-OwnedReadyJob @(@{name='app';pid=$runtime.Process.Id;creation_utc=$cim.CreationDate.ToUniversalTime().ToString('o')},@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out
 $beforeLogin=State $c.runtime_db 'runtime-before-login';EqualState $runtimePre $beforeLogin
 $admission=Join-Path $out 'full-runtime-admission.json';Write-OwnedJson $admission @{scope='S13_FULL_C2_NEW_RESTORED_RUNTIME';database=$c.runtime_db;version='0.7.3';app_sha256=$c.app_sha;app_pid=$runtime.Process.Id;native_creation=$creation;cim_creation=$cim.CreationDate.ToUniversalTime().ToString('o');outer_ready_sha256=Get-OwnedHash (Join-Path $out 'ready-response.json');database_identity_sha256=Get-OwnedHash (Join-Path $out 'runtime-identity.stdout');startup_full_unchanged=$true}
 $probe=@{scope='s13-full-recovery-http';mode='http';version='0.7.3';database=$c.runtime_db;app_port=3097;pg_port=5465;output_directory=$out;deadline_utc=$c.deadline_utc;app_sha256=$c.app_sha;before=$beforeLogin;runtime_admission=@{path=$admission;sha256=Get-OwnedHash $admission};credentials_private=$c.credentials_private;credential_native_record=$c.credential_native_record;credential_result=$c.credential_result}
 $pc=Join-Path $out 'full-http-config.json';Write-OwnedJson $pc $probe
 [void](Native 'full-http-probe' $c.node $c.node_sha @($c.probe,$pc) @{PI_FULL_RECOVERY_CONFIG_SHA=(Get-OwnedHash $pc).ToLowerInvariant()} 660 1MB)
 $after=State $c.runtime_db 'runtime-after-http';$offlineAfter=State $c.recovery_db 'offline-recovery-after';EqualState $recoveryPre $offlineAfter
 $runtimeCatalogAfter=Catalog $c.runtime_db 'runtime-catalog-after';$offlineCatalogAfter=Catalog $c.recovery_db 'offline-catalog-after';EqualState $runtimeCatalogPre $runtimeCatalogAfter;EqualState $offlineCatalogPre $offlineCatalogAfter
 $probe.mode='delta';$probe.after=$after;$probe.http_witness=@{path=Join-Path $out 'full-http-private-witness.json';sha256=Get-OwnedHash (Join-Path $out 'full-http-private-witness.json')}
 $dc=Join-Path $out 'full-http-delta-config.json';Write-OwnedJson $dc $probe
 [void](Native 'full-http-exact-delta' $c.node $c.node_sha @($c.probe,$dc) @{PI_FULL_RECOVERY_CONFIG_SHA=(Get-OwnedHash $dc).ToLowerInvariant()} 180 1MB)
 [void](Native 'full-export-reference' $c.export_reference.path $c.export_reference.sha256 @($beforeLogin.path,$beforeLogin.sha256,[string]$beforeLogin.bytes,$out) @{} 180 1MB)
 $referenceResult=Get-Content (Join-Path $out 'full-export-reference.stdout') -Raw|ConvertFrom-Json
 if($referenceResult.status -cne 'FULL_ORIGINAL_C2_ALL_EXPORT_FIELDS_AND_BPMN_REFERENCE_MATCH_PENDING_QA_TD' -or $referenceResult.SQL_rows -ne 130 -or $referenceResult.legacy_repository_rows -ne 10 -or $referenceResult.log_exports -ne 20 -or $referenceResult.model_JSON_BPMN_pairs -ne 14){throw 'recovery_complete_reference_coverage_required'}
 Write-OwnedJson (Join-Path $out 'full-export-reference-binding.json') @{reference_executable_sha256=$c.export_reference.sha256;reference_source_sha256=$c.export_reference_source.sha256;build_native_sha256=$c.export_reference_build.sha256;selftest_native_sha256=$c.export_reference_selftest.sha256;actual_reference_stdout_sha256=Get-OwnedHash (Join-Path $out 'full-export-reference.stdout');actual_reference_native_sha256=Get-OwnedHash (Join-Path $out 'full-export-reference-native.json');input_sql_sha256=$beforeLogin.sha256;result=$referenceResult;acceptance='PENDING_QA_TD_NOT_WHOLE_R3'}
 foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256};Budget
 Write-OwnedJson (Join-Path $out 'full-recovery-http-result.json') @{status='CURRENT_FULL_C2_ORIGINAL_PRE_RECOVERY_COMPATIBILITY_EVIDENCE_PENDING_QA_TD';runtime_input='ORIGINAL_FULL_130_ROW_PRE_NOT_POST';input_full_proof_sha256=$c.full_current_proof.sha256;pre_archive_sha256=$c.pre_archive_sha;post_archive_lineage_sha256=$c.post_archive_sha;runtime_pre=$runtimePre;before_login=$beforeLogin;runtime_after=$after;offline_recovery_pre=$recoveryPre;offline_recovery_after=$offlineAfter;runtime_catalog_pre=$runtimeCatalogPre;runtime_catalog_after=$runtimeCatalogAfter;offline_catalog_pre=$offlineCatalogPre;offline_catalog_after=$offlineCatalogAfter;http_summary_sha256=Get-OwnedHash (Join-Path $out 'full-http-summary.json');exact_delta_sha256=Get-OwnedHash (Join-Path $out 'full-http-delta.json');limits=@('Runtime restored from full original130rowPRE9959, ten legacy repositories retained','POST success proof/archive is lineage only, not runtime input','Complete export JSON and BPMN serializer reference actual native0; same public primitives, independently audited captures required','Write RBAC/destructive C08/browser/Datastar OPEN','Not full C18/R3 acceptance; verification source DBs never served or logged in','Only this NEW PRE runtime and offline PRE recovery used')}
 $success=$true
}finally{
 try{if($runtime){if(!$runtime.Process.HasExited){$again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id);if(!$again -or $again.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'recovery_final_app_identity'};$runtime.Process.Kill()};if(!$runtime.Process.WaitForExit(10000)){throw 'recovery_final_app_stop'};$ended=Complete-OwnedCapturedProcess $runtime;Write-OwnedJson (Join-Path $out 'full-http-runtime-forced-stop.json') @{native=$ended;controlled_forced_stop=$true;no_clean_exit_claim=$true};if(!$ended.stdout_complete -or !$ended.stderr_complete -or $ended.capture_fault -or $ended.output_limit -or $ended.drain_timeout){throw 'recovery_app_full_streams'}}}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}
}
if(!$success){throw 'recovery_incomplete_retained'}
<# SOURCE-ONLY, never executed while drafting. Exact actual current fullC2 success,
full producer0/EOF+actual PRE backup/manifest for original130row runtime and offline
PRErecovery; actualPOST backup/manifest retained as lineage +all3 authored input
reviews required. Historical four matched credentials source4962/check02 proofs
are READ-ONLY inputs; no old login/reset/server. Resourcehelper current config pin
requires separate fresh allfile meter+WHOLE uncompressed4e9 capture/DB/WAL/temp/
archive/extract peak BEFORE package or PG. Initialfree8/floor4/1800s/freeze unchanged.
No future Council decision silently adopted. Fullstartup bytecompare before login;
Runtime restored from PRE614304123/9959, not cleanedPOST; all ten repository/* KV
rows retained. Offline PRE recovery never served; original verification/source untouched.
Read-only C2 capture timezone Etc/GMT-5 preserves originalledger display; no production
timezone/SQL5/lock2/TX10 change. Four complete logicalcatalog captures add<=64MiB
within unchanged4e9 capture reserve. Probe streams all130rows, never filterslegacy.
Node actual4login and all20 normalized analyses/stored metadata/modelJSON + full
BPMN capture. Independent delta replays source8h expiry pruning, new sessions,
switches and Authversion exactly; every other complete raw managed row unchanged.
No wholeAuth ignore or automatic tolerance for lazy-header mutations. Such changes
FAIL retained, not hidden. Complete Rust export/BPMN reference now required; write matrix
remain explicit OPEN; no fullC18/C08/R3 acceptance. All paths/pins/native mappings
need Root/QA/TD review before config/launch; credentials/cookies never printed.
#>
