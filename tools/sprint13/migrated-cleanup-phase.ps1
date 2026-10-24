param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY C1 draft. Current genuine03 migration -> cleanup, no oldC2 proof.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'c1_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'c1_module_before_import'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-genuine03-current-migrated-c1-cleanup' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5465 -or $c.app_port -ne 3097 -or $c.database -cne 'process_intelligence' -or $c.source_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'c1_exact_scope'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$privateRoot=Join-Path $workspace '.local/sprint13'
$names=@($c.source_db,$c.restore_db,$c.repeat_db,$c.recovery_db)
if(@($names|Select-Object -Unique).Count -ne 4 -or @($names|Where-Object {$_ -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'}).Count){throw 'c1_distinct_new_names'}
foreach($pair in @(@($c.original_archive,(Join-Path $workspace '.local/sprint09/qa/old03-full-frozen.dump')),@($c.original_values,(Join-Path $workspace '.local/sprint09/qa/old03-full-values01.jsonl')),@($c.capture_sql,(Join-Path $PSScriptRoot 'managed-state.sql')),@($c.catalog_sql,(Join-Path $PSScriptRoot 'logical-catalog.sql')),@($c.forward_oracle,(Join-Path $PSScriptRoot 'historical-state-oracle.cjs')),@($c.post_oracle,(Join-Path $PSScriptRoot 'complete-post-oracle.cjs')),@($c.receipt_oracle,(Join-Path $PSScriptRoot 'receipt-oracle.cjs')))){
 if((Get-OwnedCanonicalPath $pair[0]) -cne (Get-OwnedCanonicalPath $pair[1])){throw 'c1_literal_readonly_inputs'}
 Assert-OwnedNoReparse $pair[0]
}
foreach($pin in @(@($c.original_archive,'E0F3F91B3D7461A1D6202DC08B30BCC7F7F1CAA1CB0D9F7D3891D70771D02E7C'),@($c.original_values,'79AE70BEC3E552C38B79C1B28E05AA1C4C785B4AE3B0475F70BEC1281CE0256D'),@($c.original_sequence,'931E8CA916B849DF00377FF481B22F05C1A5AD135DCA0313203D5CA6B64B0232'),@($c.source_hashes,'43F440A9866F270C06ED41B2AFB04D3F67D89A71529BCFAD5C5B37D0EE9774D1'),@($c.capture_sql,'65611973FCDF6D6C172BF22EB9B2A9CC19A0F21615634BBDEFD4F2732E87AEB0'),@($c.catalog_sql,$c.catalog_sql_sha),@($c.forward_oracle,'A90D3FA1B487F1FD2637A21F75971F37E59E52412E39D89B2D78DE260B6E4C91'),@($c.post_oracle,'F15990C3CC4F88232776F6964E0749F30324D484ABF3B744A6084A05C3865EE5'),@($c.receipt_oracle,'71686E5D82F6A5F561A9FFE3B098703EBF81159B416C175DDC2F142C9C81E17C'),@($c.pwsh,$c.pwsh_sha),@($c.node,$c.node_sha),@($c.stdio_wrapper,$c.stdio_sha))){Assert-OwnedHash $pin[0] $pin[1]}
if((Get-Item -LiteralPath $c.original_archive).Length -ne 3972748 -or (Get-Item -LiteralPath $c.original_values).Length -ne 307160864 -or $c.normalized_checksum.ToUpperInvariant() -cne '3CC163D6799BE361E766E3366E20BC6BAA38534E6AFF630C9085B03F75DBDA1E'){throw 'c1_original_and_current_ddl_binding'}
foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256}
$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$install=Get-OwnedCanonicalPath $c.install_parent
if($out -ceq $install -or $out.StartsWith($install.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $install.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'c1_separate_output_install'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or $started -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'c1_initial_capacity_freeze'}
# No compression assumption. Upper capture reservation6e9 includes original raw
# capture, six650MB currentPRE slots and five350MB POST/derived slots.
if($c.capture_reservation_bytes -ne 6000000000L){throw 'c1_capture_reservation_unchanged'}
$resourceBudget=New-S13PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S13PhaseBudget -Proof $resourceBudget -Next $Next}
Budget
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $install $c.manifest_sha
$manifest=Get-Content -LiteralPath (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($manifest.version -cne '0.7.3' -or $manifest.source_commit -cne $c.source_commit -or $manifest.build_proof.executable_sha256 -cne $c.app_sha){throw 'c1_current_package_binding'}
$exe=Join-Path $pkg 'process-intelligence-rs.exe';Assert-OwnedHash $exe $c.app_sha
$bin=Join-Path $pkg 'runtime/postgresql/pgsql/bin';$psql=Join-Path $bin 'psql.exe';Assert-OwnedHash $psql $c.psql_sha
$backup=Join-Path $pkg 'tools/database-backup.ps1';Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$admin=$null;$applyEnv=$null;$emptyEnv=$null;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=4MB){
 Budget
 $p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'c1_owned_child_stop_timeout'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;automatic_retry=$false}
 if($forced -or $r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('c1_native_failed_'+$Label)}
 Budget;return $r
}
function Sql([string]$Database,[string]$Label,[string[]]$Arguments,[long]$Cap=16MB,[bool]$Readonly=$true){
 if($Database -cnotin ($names+@('postgres'))){throw 'c1_sql_new_scope'}
 $envSql=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 if($Readonly){$envSql.PGOPTIONS+=' -c default_transaction_read_only=on'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-d',$Database)+$Arguments
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment $envSql -Seconds 120 -Cap $Cap
}
function State([string]$Database,[string]$Label,[bool]$Catalog=$false){
 $sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$cap=if($Catalog){16MB}else{1GB};Budget $cap
 $r=Sql -Database $Database -Label $Label -Arguments @('-f',$sql) -Cap $cap
 return @{database=$Database;path=(Join-Path $out ($Label+'.stdout'));sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native_exit=$r.native_exit;sql_sha256=(Get-OwnedHash $sql)}
}
function EqualState($A,$B){if($A.bytes -ne $B.bytes -or $A.sha256.ToUpperInvariant() -cne $B.sha256.ToUpperInvariant()){throw 'c1_complete_state_changed'}}
function Stock([string]$Label,[hashtable]$Arguments){
 [string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Arguments|ConvertTo-Json -Compress))
 return Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180
}
function Oracle([string]$Label,[string[]]$Arguments){[string[]]$argv=@($c.forward_oracle)+$Arguments;return Native -Label $Label -Program $c.node -Sha $c.node_sha -Arguments $argv -Seconds 180 -Cap 1MB}
function Identity([string]$Database,[string]$Label){
 [void](Sql -Database $Database -Label $Label -Arguments @('-c',"SELECT jsonb_build_object('database',current_database(),'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()),'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),'server_version_num',current_setting('server_version_num'),'encoding',current_setting('server_encoding'),'recovery',pg_is_in_recovery(),'read_only',current_setting('default_transaction_read_only'));"))
 $v=Get-Content -LiteralPath (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json
 if($v.database -cne $Database -or $v.server_version_num -cne '180006' -or $v.encoding -cne 'UTF8' -or $v.recovery -or $v.read_only -cne 'on' -or $v.database_oid -cnotmatch '^[0-9]+$' -or $v.system_identifier -cnotmatch '^[0-9]+$'){throw 'c1_actual_pg_identity'}
 $v=@{database=$v.database;database_oid=$v.database_oid;system_identifier=$v.system_identifier};Write-OwnedJson (Join-Path $out ($Label+'-receipt.json')) $v;return $v
}
function Connection([string]$Database,[string]$User='pi_admin'){if($Database -cnotin $names){throw 'c1_connection_scope'};$password=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5465 user=$User password=$password dbname=$Database connect_timeout=5"}
function Cleanup([string]$Label,[string]$Option,[hashtable]$Environment){[void](Native -Label $Label -Program $exe -Sha $c.app_sha -Arguments @($Option) -Environment $Environment -Seconds 300);return Get-Content -LiteralPath (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
try{
 $service=Start-OwnedStockService $c $pkg 'c1-stock';[void](Wait-OwnedStockService $service)
 $pg=@($service.Processes|Where-Object Name -ceq 'postgres')
 if($pg.Count -ne 1 -or $pg[0].Process.HasExited){throw 'c1_ready_pg_missing'}
 $pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$pgCim -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'c1_ready_pg_image'}
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out
 $apps=@($service.Processes|Where-Object Name -ceq 'app');if($apps.Count -ne 1 -or !$service.Job.Member($apps[0].Handle)){throw 'c1_owned_app_identity'}
 $held=$apps[0];$actual=Get-CimInstance Win32_Process -Filter ('ProcessId='+$held.Process.Id)
 if(!$actual -or $held.Process.HasExited -or $actual.ExecutablePath -cne $exe -or $held.Process.StartTime.ToUniversalTime().ToString('o') -cne $held.Creation){throw 'c1_app_stale'}
 $held.Process.Kill();if(!$held.Process.WaitForExit(10000) -or @(Get-NetTCPConnection -LocalPort 3097 -State Listen -ErrorAction SilentlyContinue).Count){throw 'c1_owned_app_not_offline'}
 Write-OwnedJson (Join-Path $out 'app-offline.json') @{pid=$held.Process.Id;creation=$held.Creation;native_exit=$held.Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 $secret=Get-Content -LiteralPath (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5465){throw 'c1_private_port'}
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 foreach($n in $names){$label='absent-'+$n.Substring(15).Replace('_','-');[void](Sql -Database 'postgres' -Label $label -Arguments @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$n+"');")));if((Get-Content -LiteralPath (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'c1_target_already_exists'}}
 # Genuine raw archive has NO maintained stock manifest. Explicit newDB adapter,
 # rolepi_app ownership only, never fabricate an original manifest or claim one.
 [void](Sql -Database 'postgres' -Label 'create-raw-source' -Arguments @('-c',('CREATE DATABASE "'+$c.source_db+'" OWNER pi_app;')) -Readonly $false)
 [string[]]$restoreArgs=@('-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-d',$c.source_db,'--exit-on-error','--single-transaction','--no-owner','--no-privileges','--role=pi_app',$c.original_archive)
 [void](Native -Label 'raw-original-restore' -Program (Join-Path $bin 'pg_restore.exe') -Sha $c.pg_restore_sha -Arguments $restoreArgs -Environment $admin -Seconds 180 -Cap 16MB)
 $rawPre=State $c.source_db 'raw-original-pre'
 [void](Oracle -Label 'original-full-oracle' -Arguments @('--mode','original','--legacy-values',$c.original_values,'--capture',$rawPre.path,'--sequence',$c.original_sequence))
 $originalProof=Get-Content -LiteralPath (Join-Path $out 'original-full-oracle.stdout') -Raw|ConvertFrom-Json;if($originalProof.status -cne 'FULL_ORIGINAL_TYPED_STATE_MATCHED'){throw 'c1_original_typed_state_oracle'}
 $migrationStart=[DateTime]::UtcNow.ToString('o')
 [void](Native -Label 'current-migrate' -Program $exe -Sha $c.app_sha -Arguments @('--migrate-storage') -Environment @{PI_DATABASE_URL=(Connection $c.source_db 'pi_app')} -Seconds 300)
 $migrationEnd=[DateTime]::UtcNow.ToString('o');$sourcePre=State $c.source_db 'current-full-pre'
 [string[]]$forwardArgs=@('--mode','forward','--legacy-values',$c.original_values,'--sequence',$c.original_sequence,'--source-hashes',$c.source_hashes,'--source-hashes-sha','43F440A9866F270C06ED41B2AFB04D3F67D89A71529BCFAD5C5B37D0EE9774D1','--checksum',$c.normalized_checksum,'--capture',$sourcePre.path,'--not-before',$migrationStart,'--not-after',$migrationEnd)
 [void](Oracle -Label 'current-forward-oracle' -Arguments $forwardArgs)
 $forwardProof=Get-Content -LiteralPath (Join-Path $out 'current-forward-oracle.stdout') -Raw|ConvertFrom-Json
 if($forwardProof.status -cne 'FULL_HISTORICAL_FORWARD_EXPECTED_STATE_MATCHED' -or $forwardProof.projects -ne 10 -or $sourcePre.bytes -lt 600000000 -or $sourcePre.bytes -gt 650000000){throw 'c1_current_full_forward_binding'}
 $archive=Join-Path $pkg '.local/current-migrated-pre.dump'
 [void](Stock -Label 'backup-current-pre' -Arguments @{Mode='Backup';Database=$c.source_db;BackupFile=$archive})
 $am=Get-Content -LiteralPath ($archive+'.manifest.json') -Raw|ConvertFrom-Json;if($am.database -cne $c.source_db -or !$am.includes_auth -or $am.size -ne (Get-Item -LiteralPath $archive).Length -or $am.sha256.ToUpperInvariant() -cne (Get-OwnedHash $archive)){throw 'c1_truthful_current_stock_manifest'}
 [void](Stock -Label 'restore-new-verification' -Arguments @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.restore_db;BackupFile=$archive})
 $sid=Identity $c.source_db 'source-identity';$rid=Identity $c.restore_db 'restore-identity';if($sid.system_identifier -cne $rid.system_identifier -or $sid.database_oid -ceq $rid.database_oid){throw 'c1_distinct_actual_pair'}
 $restorePre=State $c.restore_db 'verification-pre';EqualState $sourcePre $restorePre
 $sourceCatalog=State $c.source_db 'source-catalog-pre' $true;$restoreCatalog=State $c.restore_db 'restore-catalog-pre' $true;EqualState $sourceCatalog $restoreCatalog
 $plan=Join-Path $pkg '.local/current-c1.plan.json';$receipt=Join-Path $pkg '.local/current-c1.receipt.json'
 $applyEnv=@{PI_DATABASE_URL=(Connection $c.source_db);PI_CLEANUP_RESTORE_URL=(Connection $c.restore_db);PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan}
 $v=Cleanup 'current-verify' '--cleanup-storage-verify' $applyEnv
 if($v.outcome -cne 'cleanup_verified' -or $v.candidate_rows -ne 10 -or $v.plan_sha256.ToUpperInvariant() -cne (Get-OwnedHash $plan)){throw 'c1_current_verify_ten'}
 $expectedPath=Join-Path $out 'expected-current-post.stdout'
 # BEFORE Apply: exact current nativePRE hash/length, no old9959 clock assumption.
 Write-OwnedJson (Join-Path $out 'prior-native-pre-binding.json') @{source_pre=$sourcePre;verification_pre=$restorePre;forward_oracle_sha256=(Get-OwnedHash (Join-Path $out 'current-forward-oracle.stdout'));plan_sha256=(Get-OwnedHash $plan);recorded_before_apply=$true}
 [string[]]$postArgs=@($c.post_oracle,$sourcePre.path,$plan,$expectedPath,$sourcePre.sha256,[string]$sourcePre.bytes)
 [void](Native -Label 'derive-current-post' -Program $c.node -Sha $c.node_sha -Arguments $postArgs -Seconds 180 -Cap 1MB)
 $expected=Get-Content -LiteralPath (Join-Path $out 'derive-current-post.stdout') -Raw|ConvertFrom-Json
 if($expected.status -cne 'FULL_POST_ORACLE_DERIVED' -or $expected.pre_lines -ne 130 -or $expected.post_lines -ne 120 -or $expected.removed_exact_rows -ne 10 -or $expected.pre_sha256.ToUpperInvariant() -cne $sourcePre.sha256 -or $expected.pre_bytes -ne $sourcePre.bytes){throw 'c1_exact_current_post_oracle'}
 Assert-OwnedHash $expectedPath $expected.post_sha256
 $applyEnv.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $plan;$applyEnv.PI_CLEANUP_RECEIPT=$receipt
 $a=Cleanup 'current-apply' '--cleanup-storage-apply' $applyEnv;if($a.outcome -cne 'cleanup_committed' -or $a.deleted_rows -ne 10 -or $a.physical_disk_shrink -ne $false){throw 'c1_normal_committed_apply'}
 [string[]]$receiptArgs=@($c.receipt_oracle,$plan,$receipt,(Join-Path $out 'current-apply.stdout'),(Join-Path $out 'source-identity-receipt.json'),(Join-Path $out 'restore-identity-receipt.json'),$archive)
 [void](Native -Label 'receipt-full-contract' -Program $c.node -Sha $c.node_sha -Arguments $receiptArgs -Seconds 60 -Cap 1MB)
 $rp=Get-Content -LiteralPath (Join-Path $out 'receipt-full-contract.stdout') -Raw|ConvertFrom-Json;if($rp.status -cne 'COMMITTED_RECEIPT_FULL_CONTRACT_BOUND'){throw 'c1_receipt_full_contract'}
 $sourcePost=State $c.source_db 'actual-current-post';$restorePost=State $c.restore_db 'verification-after-apply';EqualState $sourcePost @{sha256=$expected.post_sha256;bytes=$expected.post_bytes};EqualState $restorePre $restorePost
 EqualState $sourceCatalog (State $c.source_db 'source-catalog-post' $true);EqualState $restoreCatalog (State $c.restore_db 'restore-catalog-post' $true)
 $postArchive=Join-Path $pkg '.local/current-post-repeat.dump';[void](Stock -Label 'backup-current-post' -Arguments @{Mode='Backup';Database=$c.source_db;BackupFile=$postArchive})
 [void](Stock -Label 'restore-empty-pair' -Arguments @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.repeat_db;BackupFile=$postArchive})
 $repeatPre=State $c.repeat_db 'repeat-pre';EqualState $sourcePost $repeatPre;$repeatCatalog=State $c.repeat_db 'repeat-catalog-pre' $true
 $ep=Join-Path $pkg '.local/current-empty.plan.json';$er=Join-Path $pkg '.local/current-empty.receipt.json'
 $emptyEnv=@{PI_DATABASE_URL=(Connection $c.source_db);PI_CLEANUP_RESTORE_URL=(Connection $c.repeat_db);PI_CLEANUP_ARCHIVE=$postArchive;PI_CLEANUP_PLAN=$ep}
 $ev=Cleanup 'empty-verify' '--cleanup-storage-verify' $emptyEnv;if($ev.outcome -cne 'cleanup_verified' -or $ev.candidate_rows -ne 0 -or $ev.plan_sha256.ToUpperInvariant() -cne (Get-OwnedHash $ep)){throw 'c1_empty_verify'}
 $emptyEnv.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $ep;$emptyEnv.PI_CLEANUP_RECEIPT=$er;$ea=Cleanup 'empty-apply' '--cleanup-storage-apply' $emptyEnv
 if($ea.outcome -cne 'cleanup_empty' -or $ea.deleted_rows -ne 0 -or $ea.database_writes -ne 0 -or (Test-Path -LiteralPath $er)){throw 'c1_empty_zero_write_contract'}
 $repeatSource=State $c.source_db 'empty-source-post';$repeatPost=State $c.repeat_db 'empty-restore-post';EqualState $sourcePost $repeatSource;EqualState $repeatPre $repeatPost
 EqualState $sourceCatalog (State $c.source_db 'empty-source-catalog-post' $true);EqualState $repeatCatalog (State $c.repeat_db 'empty-restore-catalog-post' $true)
 [void](Stock -Label 'restore-current-full-pre' -Arguments @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.recovery_db;BackupFile=$archive})
 [void](Identity $c.recovery_db 'recovery-identity');$recovered=State $c.recovery_db 'recovery-current-pre';EqualState $sourcePre $recovered;EqualState $sourceCatalog (State $c.recovery_db 'recovery-catalog' $true)
 $restoreFinal=State $c.restore_db 'verification-final';EqualState $restorePre $restoreFinal;EqualState $restoreCatalog (State $c.restore_db 'verification-catalog-final' $true)
 foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256};Test-OwnedPackageTree $pkg $c.manifest_sha $true;Budget
 Write-OwnedJson (Join-Path $out 'migrated-cleanup-result.json') @{status='S13_CURRENT_MIGRATED_C1_APPLY_C14_DATABASE_RECOVERY_EVIDENCE_PENDING_QA_TD';original_raw=$rawPre;forward=$forwardProof;current_pre=$sourcePre;verification_pre=$restorePre;expected_post=$expected;actual_post=$sourcePost;verification_after=$restorePost;receipt=$rp;empty_verify=$ev;empty_apply=$ea;empty_source_post=$repeatSource;empty_restore_post=$repeatPost;current_pre_recovery=$recovered;verification_final=$restoreFinal;package_sha256=$c.package_sha;app_sha256=$c.app_sha;new_plan_sha256=(Get-OwnedHash $plan);automatic_retry=$false;physical_disk_shrink=$false;no_compression_assumed=$true;limits=@('Explicit genuine rawarchive adapter with pi_app owner, no fabricated original manifest','Current ledger2 wallclock bound by actual migration interval; no9959/oldC2state reuse','C18 HTTP/export/RBAC NOT EXECUTED here','F01-F03/SQL5/lock2/tx10 separate actual phases','Zero DBwrites is CLI declaration plus complete byte equality, not continuous SQL observer','Not release or whole R3/R2-R5 acceptance')}
 $success=$true
}catch{
 $failed=@{status='FAILED_RETAINED';automatic_retry=$false;source='NOT_CAPTURED';restore='NOT_CAPTURED'}
 if($secret){try{$failed.source=State $c.source_db 'failure-source-full'}catch{$failed.source='UNAVAILABLE_OR_BUDGET_STOP'};try{$failed.restore=State $c.restore_db 'failure-restore-full'}catch{$failed.restore='UNAVAILABLE_OR_BUDGET_STOP'}}
 Write-OwnedJson (Join-Path $out 'migrated-cleanup-failed.json') $failed;throw
}finally{
 $secret=$null;$admin=$null;$applyEnv=$null;$emptyEnv=$null
 if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'}
}
if(!$success){throw 'c1_incomplete'}

<#
SOURCE-ONLY draft; no execution/config/import/native work performed in preparation.
Requires outer waiting-worker Job before GO, Root/QA/TD exact source/pins/config
review, NEW current0.7.3 package+manifest+source/EXE, new private install/output,
5465/3097 initiallyabsent actualowned servicePID/creation/image/datadir/Job; app
stoppedbefore offlineSQL; finally maintained pg_ctl faststop actualPGexit0 proof.
Config scope/version/ports/defaultdb asabove, fourdistinct pi_restore_s13_* names,
source_commit/package_archive/package_sha/manifest_sha/app_sha, all helpers/worker/
pwsh/node/PG/backup/stdio pins, fixedreadonly originalarchiveE0F3, original79AE,
sequence931E, Rustfixture43F440, forwardoracleA90, currentDDL3CC, managedSQL6561,
currentreviewedlogicalcatalogconfigpin, postoracleF159, receiptoracle7168. Original dump NOstockmanifest;
new current migratedsource backup creates truthfulstockmanifest. Rolepi_app raw
restore/migrate unchanged production semantics; independent read-only SQL60s only,
productioncleanup5/2/10 unchanged. No permission bypass or timeout extensions.
Fullcurrent130PRE forwardoracle must pass beforeVerify/derive/Apply; actualnative
currentPRE SHA/bytes boundbeforeApply; all120POSTrows exacttenKV filter independent.
C14 newPOSTstockrestore+emptyVerify/Apply/fullbyteconservation; separate NEWcurrent
PREstockrecovery/fullvalue equality; never C18 HTTPcredit or oldC2proof reuse.
Initial8GiBfree/floor4GiB/phase1800s<=runtimefreeze. Adopteddecision04/60A809 actual5FOR
40GiB allocation/40GiB logical requires SEPARATE freshcomplete native baseline
BEFORE package/PGcreation, plus FULL uncompressed phase reservation. Capture6e9
unchanged; explicit DB/WAL/temp/extract/archive>=1536MiB, wholephase<=8GiB,
phase_allocation_reservation_bytes>=phase_reservation_bytes+128MiB rounding.
Both caps add160MiB metadata+256MiB public+256MiB unmetered directory/MFT; no fit
or compressionratio assumed. phase_budget={module_sha,phase_sha,decision:{path,sha256},
db_wal_temp_extract_archive_bytes,reviews:{Root,QA,TD:{path,sha256}}}. Independent
reviews bind exact scope/package/output/install/capture/reserves/source hashes.
ActivePG logical+NEXT/fullinitialallocation+wholephase guard, no fresh activePG
nativeaggregate claim. Every State checks full1GiB NEXT before capture. Actual
fresh baseline may reject phase; no truncation/corpus cuts/optimistic savings.
Maxfullcapture1GiB/catalog16MiB/native4MiB/oracle1MiB, allEOF/native0; retain failures,
knownpartial/uncertain outcomes never retry or infer fromexit. No protectedoldSQL.
#>
