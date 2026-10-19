param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY DRAFT. Execute only through the separately admitted S13 waiting-worker Job.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'full_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){
 if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'full_module_pin'}
}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-full-c2-cleanup' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5465 -or $c.app_port -ne 3097 -or $c.database -cne 'process_intelligence' -or $c.source_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'full_finite_scope'}
$names=@($c.source_db,$c.restore_db,$c.repeat_db,$c.recovery_db)
if(@($names|Select-Object -Unique).Count -ne 4){throw 'full_distinct_names'}
foreach($n in $names){if($n -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'){throw 'full_new_database_scope'}}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..')
$oldArchive=Join-Path $workspace '.local/sprint09/qa/package-c2/process-intelligence-rs-0.7.1-windows-x86_64/.local/c2-c02-normalized01.dump'
$oldCapture=Join-Path $workspace '.local/sprint11/root/sql5-inputs01/capture.sql'
foreach($p in @(@($c.original_archive,$oldArchive),@($c.capture_sql,$oldCapture),@($c.post_oracle,(Join-Path $PSScriptRoot '../cleanup-post-oracle.cjs')),@($c.receipt_oracle,(Join-Path $PSScriptRoot 'receipt-oracle.cjs')))){
 if((Get-OwnedCanonicalPath $p[0]) -cne (Get-OwnedCanonicalPath $p[1])){throw 'full_literal_readonly_inputs'}
}
Assert-OwnedHash $c.original_archive '3A0E6E244384D141A326345E0161AEC0AFA7EC9AF2563E9C03CBDD1B04770274'
Assert-OwnedHash ($c.original_archive+'.manifest.json') $c.original_manifest_sha
$originalManifest=Get-Content -LiteralPath ($c.original_archive+'.manifest.json') -Raw|ConvertFrom-Json
if($originalManifest.database -cne 'pi_restore_s9_c2_c18app01' -or $originalManifest.size -ne 7943113 -or $originalManifest.sha256.ToUpperInvariant() -cne '3A0E6E244384D141A326345E0161AEC0AFA7EC9AF2563E9C03CBDD1B04770274' -or !$originalManifest.includes_auth -or $originalManifest.format -cne 'postgres_custom'){throw 'full_original_manifest'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.pwsh,$c.pwsh_sha),@($c.node,$c.node_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha),@($c.post_oracle,$c.post_oracle_sha),@($c.receipt_oracle,$c.receipt_oracle_sha),@((Join-Path $PSScriptRoot 'historical-state-oracle.cjs'),$c.decimal_parser_sha))){Assert-OwnedHash $p[0] $p[1]}
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
if((Get-OwnedCanonicalPath $c.install_parent) -ceq (Get-OwnedCanonicalPath $out) -or (Get-OwnedCanonicalPath $c.install_parent).StartsWith((Get-OwnedCanonicalPath $out).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Get-OwnedCanonicalPath $out).StartsWith((Get-OwnedCanonicalPath $c.install_parent).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'full_separate_install_evidence'}
$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
$started=[DateTime]::UtcNow
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or $started -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'full_capacity_or_freeze_admission'}
# Exact capture reservation: 6 PRE-sized and 4 POST-sized files, plus derived POST.
# This deliberately retains all full values, not only fingerprints or row counts.
$captureReservation=6L*614304123L+5L*307159782L
if($c.capture_reservation_bytes -ne $captureReservation){throw 'full_capture_reservation_unchanged'}
$resourceBudget=New-S13PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$manifest=Get-Content -LiteralPath (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($manifest.version -cne '0.7.3' -or $manifest.source_commit -cne $c.source_commit){throw 'full_current_package_binding'}
$exe=Join-Path $pkg 'process-intelligence-rs.exe';Assert-OwnedHash $exe $c.app_sha
$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';Assert-OwnedHash $psql $c.psql_sha
$backup=Join-Path $pkg 'tools/database-backup.ps1';Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$admin=$null;$applyEnv=$null;$emptyEnv=$null;$success=$false
function Budget([long]$Next=0){Assert-S13PhaseBudget -Proof $resourceBudget -Next $Next}
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=4MB){
 Budget
 $p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $end=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){
  if([DateTime]::UtcNow -ge $end -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'full_owned_child_stop_deadline'};break}
 }
 $r=Complete-OwnedCapturedProcess $p
 Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;no_retry=$true}
 if($forced -or $r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.capture_fault -or $r.output_limit -or $r.drain_timeout){throw ('full_native_failed_'+$Label)}
 return $r
}
function Sql([string]$Database,[string]$Label,[string[]]$Arguments,[long]$Cap=16MB){
 if($Database -cnotin ($names+@('postgres'))){throw 'full_sql_new_scope'}
 return Native $Label $psql $c.psql_sha (@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-d',$Database)+$Arguments) $admin 120 $Cap
}
function State([string]$Database,[string]$Label,[bool]$Catalog=$false){
 $sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$cap=if($Catalog){16MB}else{1GB}
 Budget $cap
 $r=Sql $Database $Label @('-f',$sql) $cap
 return @{database=$Database;path=(Join-Path $out ($Label+'.stdout'));sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native_exit=$r.native_exit;sql_sha256=(Get-OwnedHash $sql);read_only_capture_statement_budget_ms=60000}
}
function EqualState($Left,$Right){if($Left.sha256.ToUpperInvariant() -cne $Right.sha256.ToUpperInvariant() -or $Left.bytes -ne $Right.bytes){throw 'full_complete_state_changed'}}
function FullPre($State){if($State.bytes -ne 614304123 -or $State.sha256.ToUpperInvariant() -cne '9959D3E9E746460C0C52853D139DCBCCFF37EE230907537AB437FCFE33933DA1'){throw 'full_unreduced_pre_mismatch'}}
function Stock([string]$Label,[hashtable]$Arguments){
 return Native $Label $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Arguments|ConvertTo-Json -Compress)) @{} 180 4MB
}
function Identity([string]$Database,[string]$Label){
 [void](Sql $Database $Label @('-c',"SELECT jsonb_build_object('database',current_database(),'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()),'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),'server_version_num',current_setting('server_version_num'),'encoding',current_setting('server_encoding'),'recovery',pg_is_in_recovery(),'read_only',current_setting('default_transaction_read_only'));"))
 $v=Get-Content -LiteralPath (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json
 if($v.database -cne $Database -or $v.server_version_num -cne '180006' -or $v.encoding -cne 'UTF8' -or $v.recovery -or $v.read_only -cne 'on' -or $v.database_oid -cnotmatch '^[0-9]+$' -or $v.system_identifier -cnotmatch '^[0-9]+$'){throw 'full_actual_pg_identity'}
 $identity=@{database=$v.database;database_oid=$v.database_oid;system_identifier=$v.system_identifier}
 Write-OwnedJson (Join-Path $out ($Label+'-receipt.json')) $identity
 return $identity
}
function Connection([string]$Database){return "host=127.0.0.1 port=5465 user=pi_admin password=$($secret.admin_password) dbname=$Database connect_timeout=5"}
function Cleanup([string]$Label,[string]$Option,[hashtable]$Environment){
 $r=Native $Label $exe $c.app_sha @($Option) $Environment 300 4MB
 $v=Get-Content -LiteralPath (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 return $v
}
try{
 $service=Start-OwnedStockService $c $pkg 'full-stock';[void](Wait-OwnedStockService $service)
 $pg=@($service.Processes|Where-Object Name -ceq 'postgres')
 if($pg.Count -ne 1 -or $pg[0].Process.HasExited){throw 'full_ready_pg_missing'}
 $pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$pgCim -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'full_ready_pg_image'}
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out
 # Maintained bootstrap starts an app; stop the exact retained app BEFORE restoring offline data.
 $apps=@($service.Processes|Where-Object Name -ceq 'app')
 if($apps.Count -ne 1 -or !$service.Job.Member($apps[0].Handle)){throw 'full_owned_app_identity'}
 $held=$apps[0];$again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$held.Process.Id)
 if($held.Process.HasExited -or !$again -or $again.ExecutablePath -cne $exe -or $held.Process.StartTime.ToUniversalTime().ToString('o') -cne $held.Creation){throw 'full_owned_app_stale'}
 $held.Process.Kill();if(!$held.Process.WaitForExit(10000)){throw 'full_owned_app_stop_deadline'}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3097 -ErrorAction SilentlyContinue).Count){throw 'full_app_listener_remains'}
 Write-OwnedJson (Join-Path $out 'app-offline-stop.json') @{pid=$held.Process.Id;creation_utc=$held.Creation;native_exit=$held.Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 $secret=Get-Content -LiteralPath (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
 if($secret.port -ne 5465){throw 'full_private_port'}
 # Independent all-value captures only; production cleanup still supplies its own unchanged 5/2/10 limits.
 # Match the immutable C2 reference capture's fixed UTC+05 display domain.
 # This read-only psql setting never enters the production cleanup connection.
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=Etc/GMT-5 -c DateStyle=ISO,YMD'}
 foreach($n in $names){
  $absentLabel='absent-'+$n.Substring(15).Replace('_','-')
  [void](Sql 'postgres' $absentLabel @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$n+"');")))
  if((Get-Content -LiteralPath (Join-Path $out ($absentLabel+'.stdout')) -Raw).Trim() -cne 'f'){throw 'full_target_must_be_new'}
 }
 $input=Join-Path $pkg '.local/original-full-pre.dump'
 [IO.File]::Copy($c.original_archive,$input,$false);[IO.File]::Copy(($c.original_archive+'.manifest.json'),($input+'.manifest.json'),$false)
 Assert-OwnedHash $input '3A0E6E244384D141A326345E0161AEC0AFA7EC9AF2563E9C03CBDD1B04770274'
 [void](Stock 'restore-full-source' @{Mode='Restore';Database=$originalManifest.database;TargetDatabase=$c.source_db;BackupFile=$input})
 $archive=Join-Path $pkg '.local/full-pre-source.dump'
 [void](Stock 'backup-new-source' @{Mode='Backup';Database=$c.source_db;BackupFile=$archive})
 $am=Get-Content -LiteralPath ($archive+'.manifest.json') -Raw|ConvertFrom-Json
 if($am.database -cne $c.source_db -or !$am.includes_auth -or $am.size -ne (Get-Item -LiteralPath $archive).Length -or $am.sha256.ToUpperInvariant() -cne (Get-OwnedHash $archive)){throw 'full_new_truthful_manifest'}
 [void](Stock 'restore-verification' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.restore_db;BackupFile=$archive})
 $sourceIdentity=Identity $c.source_db 'source-identity';$restoreIdentity=Identity $c.restore_db 'restore-identity'
 if($sourceIdentity.database_oid -ceq $restoreIdentity.database_oid -or $sourceIdentity.system_identifier -cne $restoreIdentity.system_identifier){throw 'full_actual_distinct_database_pair'}
 $sourcePre=State $c.source_db 'source-pre';$restorePre=State $c.restore_db 'restore-pre';FullPre $sourcePre;FullPre $restorePre;EqualState $sourcePre $restorePre
 $sourceCatalog=State $c.source_db 'source-catalog-pre' $true;$restoreCatalog=State $c.restore_db 'restore-catalog-pre' $true
 $plan=Join-Path $pkg '.local/full-cleanup.plan.json';$receipt=Join-Path $pkg '.local/full-cleanup.receipt.json'
 $applyEnv=@{PI_DATABASE_URL=(Connection $c.source_db);PI_CLEANUP_RESTORE_URL=(Connection $c.restore_db);PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan}
 $verified=Cleanup 'full-verify' '--cleanup-storage-verify' $applyEnv
 if($verified.outcome -cne 'cleanup_verified' -or $verified.candidate_rows -ne 10 -or $verified.plan_sha256.ToUpperInvariant() -cne (Get-OwnedHash $plan)){throw 'full_current_verify_ten'}
 $p=Get-Content -LiteralPath $plan -Raw|ConvertFrom-Json
 if(@($p.candidates).Count -ne 10 -or $p.source.database -cne $c.source_db -or $p.restore.database -cne $c.restore_db){throw 'full_actual_new_plan_binding'}
 $expectedPath=Join-Path $out 'expected-post.stdout'
 [void](Native 'derive-full-post' $c.node $c.node_sha @($c.post_oracle,$sourcePre.path,$plan,$expectedPath) @{} 120 1MB)
 $expected=Get-Content -LiteralPath (Join-Path $out 'derive-full-post.stdout') -Raw|ConvertFrom-Json
 if($expected.status -cne 'FULL_POST_ORACLE_DERIVED' -or $expected.removed_exact_rows -ne 10 -or $expected.post_bytes -ne 307159782 -or $expected.post_sha256.ToUpperInvariant() -cne '4F3055304BF6B6B3CAFFD7C5D9EE8D7E3C021AE031B03D36B5A3981EB77DE256'){throw 'full_exact_post_oracle'}
 Assert-OwnedHash $expectedPath $expected.post_sha256
 $applyEnv.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $plan;$applyEnv.PI_CLEANUP_RECEIPT=$receipt
 $applied=Cleanup 'full-apply' '--cleanup-storage-apply' $applyEnv
 if($applied.outcome -cne 'cleanup_committed' -or $applied.deleted_rows -ne 10 -or $applied.physical_disk_shrink -ne $false){throw 'full_normal_apply_outcome'}
 [void](Native 'receipt-contract' $c.node $c.node_sha @($c.receipt_oracle,$plan,$receipt,(Join-Path $out 'full-apply.stdout'),(Join-Path $out 'source-identity-receipt.json'),(Join-Path $out 'restore-identity-receipt.json'),$archive) @{} 60 1MB)
 $receiptProof=Get-Content -LiteralPath (Join-Path $out 'receipt-contract.stdout') -Raw|ConvertFrom-Json
 if($receiptProof.status -cne 'COMMITTED_RECEIPT_FULL_CONTRACT_BOUND'){throw 'full_receipt_contract'}
 $sourcePost=State $c.source_db 'source-post';$restorePost=State $c.restore_db 'restore-post'
 EqualState $sourcePost @{sha256=$expected.post_sha256;bytes=$expected.post_bytes};EqualState $restorePre $restorePost
 EqualState $sourceCatalog (State $c.source_db 'source-catalog-post' $true);EqualState $restoreCatalog (State $c.restore_db 'restore-catalog-post' $true)
 # C14: freshly backed-up actual POST, distinct empty verification target and new empty plan.
 $postArchive=Join-Path $pkg '.local/full-post-repeat.dump'
 [void](Stock 'backup-actual-post' @{Mode='Backup';Database=$c.source_db;BackupFile=$postArchive})
 [void](Stock 'restore-empty-target' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.repeat_db;BackupFile=$postArchive})
 $repeatPre=State $c.repeat_db 'repeat-pre';EqualState $sourcePost $repeatPre
 $repeatCatalog=State $c.repeat_db 'repeat-catalog-pre' $true
 [void](Identity $c.repeat_db 'repeat-identity')
 $emptyPlan=Join-Path $pkg '.local/empty-cleanup.plan.json';$emptyReceipt=Join-Path $pkg '.local/empty-cleanup.receipt.json'
 $emptyEnv=@{PI_DATABASE_URL=(Connection $c.source_db);PI_CLEANUP_RESTORE_URL=(Connection $c.repeat_db);PI_CLEANUP_ARCHIVE=$postArchive;PI_CLEANUP_PLAN=$emptyPlan}
 $ev=Cleanup 'empty-verify' '--cleanup-storage-verify' $emptyEnv
 if($ev.outcome -cne 'cleanup_verified' -or $ev.candidate_rows -ne 0 -or $ev.plan_sha256.ToUpperInvariant() -cne (Get-OwnedHash $emptyPlan)){throw 'full_empty_verify'}
 $ep=Get-Content -LiteralPath $emptyPlan -Raw|ConvertFrom-Json
 if(@($ep.candidates).Count -ne 0){throw 'full_empty_plan'}
 $emptyEnv.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $emptyPlan;$emptyEnv.PI_CLEANUP_RECEIPT=$emptyReceipt
 $ea=Cleanup 'empty-apply' '--cleanup-storage-apply' $emptyEnv
 if($ea.outcome -cne 'cleanup_empty' -or $ea.deleted_rows -ne 0 -or $ea.database_writes -ne 0 -or (Test-Path -LiteralPath $emptyReceipt)){throw 'full_empty_apply_zero_contract'}
 $repeatSourcePost=State $c.source_db 'repeat-source-post';$repeatRestorePost=State $c.repeat_db 'repeat-restore-post'
 EqualState $sourcePost $repeatSourcePost;EqualState $repeatPre $repeatRestorePost
 EqualState $sourceCatalog (State $c.source_db 'repeat-source-catalog-post' $true);EqualState $repeatCatalog (State $c.repeat_db 'repeat-restore-catalog-post' $true)
 # C18 database restoration only. Application/export/RBAC must run in a separate admitted phase.
 [void](Stock 'restore-full-recovery' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.recovery_db;BackupFile=$archive})
 [void](Identity $c.recovery_db 'recovery-identity')
 $recovered=State $c.recovery_db 'recovery-pre';FullPre $recovered;EqualState $sourcePre $recovered
 EqualState $sourceCatalog (State $c.recovery_db 'recovery-catalog' $true)
 $verificationFinal=State $c.restore_db 'verification-final';EqualState $restorePre $verificationFinal
 EqualState $restoreCatalog (State $c.restore_db 'verification-catalog-final' $true)
 Test-OwnedPackageTree $pkg $c.manifest_sha $true
 Budget
 Write-OwnedJson (Join-Path $out 'full-cleanup-evidence.json') @{status='S13_FULL_C02_C14_C18_DATABASE_RESTORE_EVIDENCE_PENDING_QA_TD';package_sha256=$c.package_sha;executable_sha256=$c.app_sha;source_commit=$c.source_commit;input_archive_sha256=(Get-OwnedHash $input);actual_source_archive_sha256=(Get-OwnedHash $archive);actual_new_plan_sha256=(Get-OwnedHash $plan);full_source_pre=$sourcePre;full_restore_pre=$restorePre;actual_source_post=$sourcePost;restore_post=$restorePost;derived_post=$expected;receipt=$receiptProof;empty_verify=$ev;empty_apply=$ea;repeat_source_post=$repeatSourcePost;repeat_restore_post=$repeatRestorePost;full_recovery_pre=$recovered;verification_final=$verificationFinal;capture_reservation_bytes=$captureReservation;phase_reservation_bytes=$c.phase_reservation_bytes;production_budgets=@{sql_ms=5000;lock_ms=2000;transaction_ms=10000};capture_statement_ms=60000;physical_disk_shrink=$false;automatic_retry=$false;limits=@('No old EXE or old runtime proof credit','C18 application/export/RBAC NOT EXECUTED here','F01-F03/protocol boundary/SQL5 and remaining negative cases separate','Empty zero writes is actual CLI declaration plus full byte equality, not continuous SQL write trace','Not whole R3/R2-R5 or release acceptance')}
 $success=$true
}catch{
 # A nonzero Apply is never retried or classified from its exit alone. Attempt
 # complete independent failure-state captures; a failed/budget-limited capture
 # remains explicitly unavailable rather than being replaced with old evidence.
 $failureState=@{status='FAILED_RETAINED';automatic_retry=$false;source='NOT_CAPTURED';restore='NOT_CAPTURED';catalog='NOT_CAPTURED';no_success_claim=$true}
 if($secret -and $admin){
  try{$failureState.source=State $c.source_db 'failure-source-state'}catch{$failureState.source='CAPTURE_FAILED_OR_NOT_YET_CREATED_RETAINED'}
  try{$failureState.restore=State $c.restore_db 'failure-restore-state'}catch{$failureState.restore='CAPTURE_FAILED_OR_NOT_YET_CREATED_RETAINED'}
  try{$failureState.catalog=State $c.source_db 'failure-source-catalog' $true}catch{$failureState.catalog='CAPTURE_FAILED_OR_NOT_YET_CREATED_RETAINED'}
 }
 Write-OwnedJson (Join-Path $out 'full-failure-state.json') $failureState
 throw
}finally{
 $secret=$null;$admin=$null;$applyEnv=$null;$emptyEnv=$null
 # Retained exact inner Job, image/creation/datadir and loopback listener proof was obtained before SQL.
 # Helper issues pg_ctl fast stop and requires actual retained postmaster exit0 before Job closure.
 if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'}
}
if(!$success){throw 'full_phase_incomplete'}

<#
UNEXECUTED SOURCE DRAFT; no config defaults, no current package SHA invented.
Root/QA/TD must freeze this file and exact current0.7.3 package/manifest/source/EXE,
all helpers/PS7/Node/PG binaries, immutable capture.sql/catalog.sql and both oracles
plus receipt parser dependency. Outer run-owned-process waiting worker must own
all descendants BEFORE GO. New5465/new3097 ports absent first; stock service proves
retained actual PID/creation/image/Job/datadir/listener. App is stopped offline;
only owned PG is finally fast-stopped, actual native exit0 required. No global kill.

Config: scope s13-full-c2-cleanup/version0.7.3/database process_intelligence,
pg_port5465/app_port3097; distinct source_db/restore_db/repeat_db/recovery_db each
pi_restore_s13_*, private output_directory/newinstall_parent, deadline_utc<=runtime
freeze19:44:42Z, source_commit/package_archive/package_sha/manifest_sha/app_sha;
module_sha/phase_support_sha/service_sha/worker_sha/pwsh/pwsh_sha/node/node_sha,
stdio_wrapper/stdio_sha/postgres_sha/pg_ctl_sha/psql_sha/backup_sha and pins[].
original_archive fixed read-only C2 path above/original_manifest_sha;
capture_sql immutable original path/capture_sql_sha; catalog_sql/catalog_sql_sha
must be independently reviewed COMPLETE logical catalog (not physical databaseOID)
covering all managed definitions, constraints, indexes, triggers/RLS and sequence
definition. post_oracle/post_oracle_sha/receipt_oracle/receipt_oracle_sha plus
decimal_parser_sha pinned. No guessed original plan/OID/sequence/build fallback.

Upfront storage: capture_reservation_bytes=5221623648 (six614304123 plus five
307159782, including derivedPOST). Actual full-file count is FIVE PRE-sized
(sourcePRE,verificationPRE,verificationPOST,recoveryPRE,verificationFINAL) and FIVE
POST-sized (derived,sourcePOST,repeatPRE,repeatSourcePOST,repeatRestorePOST); one
extra PRE-sized reserve covers failed/extra full capture without deletion.
phase_reservation_bytes covers fullcapture plus explicit DB/WAL/temp/extract/archive
reserve>=1536MiB, <=8GiB wholephase. phase_allocation_reservation_bytes >=wholephase
+128MiB rounding. NEW phase_budget resource helper BEFORE ExpandPackage/PG: exact
decision04/60A809 actual5FOR/caps40GiB allocation40GiB logical, fresh complete native
baseline +FULLuncompressed phase +160MiB metadata+256MiB public+256MiB MFT reserves.
Initialfree8GiB and afterreserve4GiB mandatory; no fit/compressionratio assumed.
phase_budget={module_sha,phase_sha,decision:{path,sha256},
db_wal_temp_extract_archive_bytes,reviews:{Root,QA,TD:{path,sha256}}}.
Actual review records bind exact scope/package/output/install/capture/phase logical
and allocation reserves/module/phase hashes; no circular config/review SHA needed.
ActivePG budget guards use actual wholeS13/ownphase logical+NEXT and conservative
initial native+WHOLEphase allocation, never claim fresh activePG native totals.
No whole-tree old data copy/no old login/SQL. All failed captures retained, cap1GiB
per full value read/16MiB catalog/4MiB command; stdout EOF+native0 mandatory.
Identity metadata is queried in that same read-only capture session (read_only on);
actual product Verify separately enforces its own writable/no-recovery identity.
Full capture has explicitly disclosed independent read-only SQL60s budget; actual
cleanup remains unchanged5s/2s/10s and cannot inherit this PGOPTIONS. Total1800s.
Only actual current Verify10/newplan drives exact external tenKV filtering; normal
Apply0/full receipt/fullPOST, emptyfreshPOSTrepeat0 and fullPRE DBrecovery required.
Case status remains evidence pending independent review, never self-grants PASS.
#>
