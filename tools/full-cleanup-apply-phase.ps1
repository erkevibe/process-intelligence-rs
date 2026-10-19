param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$admitted=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($admitted.scope -cne 'full-c02-apply-c14-repeat-c18-restore-only' -or $admitted.cleanup_sha -cne '7FC3812772D64D9A74EEC55413C41C6C189167FFEB279EFCE2613CA7FD6AD195' -or $admitted.mode -cne 'observe'){throw 'exact_legacy_diagnostic_scope'}
foreach($p in $admitted.pins){Assert-OwnedHash $p.path $p.sha256}
Import-Module $admitted.observation_schedule -Force -DisableNameChecking
Assert-OwnedHash $admitted.observe_review $admitted.observe_review_sha
Assert-OwnedHash $admitted.hold_review $admitted.hold_review_sha
$observed=Get-Content $admitted.observe_review -Raw|ConvertFrom-Json -DateKind String
$held=Get-Content $admitted.hold_review -Raw|ConvertFrom-Json -DateKind String
if($observed.verdict -cne 'FULL_ORIGINAL_CORPUS_OBSERVE_COMPATIBILITY_VERIFIED_NOT_SQL5_TIMEOUT' -or $held.verdict -cne 'FULL_ORIGINAL_TARGET_EXTENDED_CYCLE_STATEMENT_TIMEOUT_DIAGNOSTIC_VERIFIED' -or $held.sqlstate -cne '57014' -or -not $held.actual_statement_timeout_reason){throw 'actual_full_diagnostic_gates'}
foreach($name in @($admitted.repeat_db,$admitted.recovery_db)){
 if($name -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $name -cin @($admitted.source_db,$admitted.restore_db)){throw 'new_apply_database_scope'}
}
if($admitted.repeat_db -ceq $admitted.recovery_db){throw 'distinct_new_database_scope'}
# Reuse the independently reviewed complete stock restore/Observe phase.
# This performs no deletion and supplies actual new PG Job identity and PRE.
Assert-OwnedHash $admitted.baseline_helper $admitted.baseline_helper_sha
. $admitted.baseline_helper -PhaseConfig $PhaseConfig -PhaseConfigSha $PhaseConfigSha
$secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
$admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000'}
$connection=@('-h','127.0.0.1','-p',[string]$c.port,'-U','pi_admin','-w')
function State([string]$Database,[string]$Label,[string]$Sql=$c.capture_sql,[long]$Cap=1GB){
 $r=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Database,'-At','-v','ON_ERROR_STOP=1','-f',$Sql)) $pkg $out $Label $admin 120 $Cap
 return @{database=$Database;bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256;native_exit=$r.native_exit;native_pid=$r.pid}
}
function Cleanup([string]$Label,[string]$Option,[hashtable]$Environment,[bool]$ObserveBackend=$false){
 $p=Start-OwnedCapturedProcess -Program $c.cleanup_exe -ProgramSha256 $c.cleanup_sha -Arguments @($Option) -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes 1MB -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds(300);$forced=$false;$backendWitness=$null
 $clock=[Diagnostics.Stopwatch]::StartNew();$schedule=@{attempts=0;next_ms=0;interval_ms=1000;maximum_attempts=30}
 while(-not $p.Process.WaitForExit(100)){
  if([DateTime]::UtcNow -ge $until -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(-not $p.Process.WaitForExit(10000)){throw 'apply_native_stop_timeout'};break}
  if($ObserveBackend -and -not $backendWitness -and (Get-OwnedObservationDue $schedule $clock.Elapsed.TotalMilliseconds)){
   $labelBackend=$Label+'-backend-'+$schedule.attempts
   [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d','postgres','-At','-v','ON_ERROR_STOP=1','-v',('target_database='+$c.source_db),'-f',$c.backend_sql)) $pkg $out $labelBackend $admin 10 1MB)
   $rows=@(Get-Content (Join-Path $out ($labelBackend+'.stdout'))|Where-Object {$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
   if($rows.Count -gt 1){throw 'ambiguous_apply_backend'}
   if($rows.Count -eq 1){if($rows[0].database -cne $c.source_db -or $rows[0].pid -le 0 -or $rows[0].application_name -cne 'pi_cleanup_offline'){throw 'apply_backend_identity'};$backendWitness=$rows[0]}
  }
 }
 $native=Complete-OwnedCapturedProcess $p
 $proof=@{native=$native;forced=$forced;backend_witness=$backendWitness;scope='Actual owned native command; finite safe pg_stat_activity sample is not DELETE/COMMIT wire boundary proof'}
 Write-OwnedJson (Join-Path $out ($Label+'-phase.json')) $proof
 return $proof
}
function CompleteNative([hashtable]$Proof){
 return (-not $Proof.forced -and $Proof.native.stdout_complete -and $Proof.native.stderr_complete -and -not $Proof.native.output_limit -and -not $Proof.native.capture_fault -and -not $Proof.native.drain_timeout)
}
try{
 $expectedPath=Join-Path $out 'expected-post.stdout'
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.post_oracle,(Join-Path $out 'source-pre.stdout'),$c.original_plan,$expectedPath) $c.workspace $out 'derive-post' @{} 60 1MB)
 $expected=Get-Content (Join-Path $out 'derive-post.stdout') -Raw|ConvertFrom-Json
 if($expected.status -cne 'FULL_POST_ORACLE_DERIVED' -or $expected.removed_exact_rows -ne 10 -or $expected.post_bytes -ne 307159782 -or $expected.post_sha256 -cne '4f3055304bf6b6b3caffd7c5d9ee8d7e3c021ae031b03d36b5a3981eb77de256'){throw 'exact_full_post_oracle'}
 Assert-OwnedHash $expectedPath $expected.post_sha256
 $catalogPre=State $c.source_db 'apply-catalog-pre' $c.catalog_sql 16MB
 $restoreCatalogPre=State $c.restore_db 'restore-catalog-pre' $c.catalog_sql 16MB
 $directSource="host=127.0.0.1 port=$($c.port) user=pi_admin password=$($secret.admin_password) dbname=$($c.source_db) connect_timeout=5"
 $directRestore="host=127.0.0.1 port=$($c.port) user=pi_admin password=$($secret.admin_password) dbname=$($c.restore_db) connect_timeout=5"
 $envApply=@{PI_DATABASE_URL=$directSource;PI_CLEANUP_RESTORE_URL=$directRestore;PI_CLEANUP_ARCHIVE=$newArchive;PI_CLEANUP_PLAN=$planOutput;PI_CLEANUP_CONFIRM_SHA=(Get-OwnedHash $planOutput);PI_CLEANUP_RECEIPT=(Join-Path $pkg '.local/full-apply.receipt.json')}
 $apply=Cleanup 'apply' '--cleanup-storage-apply' $envApply $true
 $sourceApplied=State $c.source_db 'source-after-apply'
 $restoreApplied=State $c.restore_db 'restore-after-apply'
 $catalogPost=State $c.source_db 'apply-catalog-post' $c.catalog_sql 16MB
 $restoreCatalogPost=State $c.restore_db 'restore-catalog-post' $c.catalog_sql 16MB
 $stateClass=if($sourceApplied.sha256 -ceq $expected.post_sha256.ToUpperInvariant()){'EXPECTED_POST'}elseif($sourceApplied.sha256 -ceq $sourcePre.sha256){'COMPLETE_PRE'}else{'UNEXPECTED_STOP'}
 $outcome=$null
 if((CompleteNative $apply) -and $apply.native.native_exit -eq 0){$outcome=Get-Content (Join-Path $out 'apply.stdout') -Raw|ConvertFrom-Json}
 $passed=(CompleteNative $apply) -and $apply.native.native_exit -eq 0 -and $apply.backend_witness -and $outcome.outcome -ceq 'cleanup_committed' -and $outcome.deleted_rows -eq 10 -and $stateClass -ceq 'EXPECTED_POST' -and $sourceApplied.bytes -eq $expected.post_bytes -and $restoreApplied.sha256 -ceq $restorePre.sha256 -and $catalogPre.sha256 -ceq $catalogPost.sha256 -and $restoreCatalogPre.sha256 -ceq $restoreCatalogPost.sha256
 Write-OwnedJson (Join-Path $out 'full-apply-result.json') @{status=$(if($passed){'FULL_C02_NORMAL_APPLY_EVIDENCE_READY_FOR_REVIEW'}else{'FAILED_RETAINED'});apply=$apply;expected_post=$expected;source_after=$sourceApplied;restore_after=$restoreApplied;source_classification=$stateClass;source_catalog_pre=$catalogPre;source_catalog_post=$catalogPost;restore_catalog_pre=$restoreCatalogPre;restore_catalog_post=$restoreCatalogPost;outcome=$outcome;automatic_retry=$false;physical_disk_shrink=$false;limits=@('Unchanged old0.7.1 diagnostic on new owned corpus only','No independent DELETE RETURNING or COMMIT wire boundary proof; F01/F02/F03 not covered','No current0.7.2 Apply or whole DISK/R3 acceptance')}
 if(-not $passed){throw 'full_apply_failed_no_retry'}
 # C14: a new POST backup/restore and freshly verified empty plan.
 $repeatArchive=Join-Path $pkg '.local/full-post-repeat.dump'
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Backup','-Database',$c.source_db,'-BackupFile',$repeatArchive) $pkg $out 'repeat-stock-backup' @{} 120)
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-BackupFile',$repeatArchive,'-TargetDatabase',$c.repeat_db) $pkg $out 'repeat-stock-restore' @{} 120)
 $repeatBefore=State $c.repeat_db 'repeat-restore-pre'
 if($repeatBefore.sha256 -cne $sourceApplied.sha256){throw 'repeat_stock_state'}
 $envRepeat=@{PI_DATABASE_URL=$directSource;PI_CLEANUP_RESTORE_URL=$directRestore.Replace(('dbname='+$c.restore_db+' '),('dbname='+$c.repeat_db+' '));PI_CLEANUP_ARCHIVE=$repeatArchive;PI_CLEANUP_PLAN=(Join-Path $pkg '.local/empty-repeat.plan.json')}
 $emptyVerify=Cleanup 'empty-verify' '--cleanup-storage-verify' $envRepeat
 if(-not (CompleteNative $emptyVerify) -or $emptyVerify.native.native_exit -ne 0){throw 'empty_verify_failed'}
 $emptyPlan=Get-Content $envRepeat.PI_CLEANUP_PLAN -Raw|ConvertFrom-Json
 if($emptyPlan.candidates.Count -ne 0){throw 'empty_plan_candidates'}
 $envRepeat.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $envRepeat.PI_CLEANUP_PLAN;$envRepeat.PI_CLEANUP_RECEIPT=Join-Path $pkg '.local/empty-repeat.receipt.json'
 $emptyApply=Cleanup 'empty-apply' '--cleanup-storage-apply' $envRepeat
 $repeatSourceAfter=State $c.source_db 'repeat-source-post';$repeatRestoreAfter=State $c.repeat_db 'repeat-restore-post'
 $emptyOutcome=Get-Content (Join-Path $out 'empty-apply.stdout') -Raw|ConvertFrom-Json
 $emptyPassed=(CompleteNative $emptyApply) -and $emptyApply.native.native_exit -eq 0 -and $emptyOutcome.outcome -ceq 'cleanup_empty' -and $emptyOutcome.deleted_rows -eq 0 -and $emptyOutcome.database_writes -eq 0 -and $sourceApplied.sha256 -ceq $repeatSourceAfter.sha256 -and $repeatBefore.sha256 -ceq $repeatRestoreAfter.sha256
 Write-OwnedJson (Join-Path $out 'empty-repeat-result.json') @{status=$(if($emptyPassed){'EMPTY_REPEAT_FINITE_EVIDENCE_READY_FOR_REVIEW'}else{'FAILED_RETAINED'});verify=$emptyVerify;apply=$emptyApply;outcome=$emptyOutcome;source_post=$repeatSourceAfter;restore_pre=$repeatBefore;restore_post=$repeatRestoreAfter;zero_writes_source='CLI declaration plus byte-exact complete managed state, not a continuous SQL writer audit'}
 if(-not $emptyPassed){throw 'empty_repeat_failed_no_retry'}
 # C18 restoration part only: recover original PRE into another new database.
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-BackupFile',$newArchive,'-TargetDatabase',$c.recovery_db) $pkg $out 'full-pre-recovery-restore' @{} 120)
 $recovered=State $c.recovery_db 'full-pre-recovered'
 if($recovered.sha256 -cne $sourcePre.sha256 -or $recovered.bytes -ne $sourcePre.bytes){throw 'full_pre_recovery_changed'}
 $restoreFinal=State $c.restore_db 'untouched-restore-final'
 if($restoreFinal.sha256 -cne $restorePre.sha256){throw 'verification_copy_changed'}
 Test-OwnedPackageTree $pkg $c.manifest_sha $true
 Write-OwnedJson (Join-Path $out 'full-cleanup-result.json') @{status='FINITE_FULL_C02_C14_C18_RESTORE_PART_EVIDENCE_READY_FOR_REVIEW';source_classification=$stateClass;full_pre_recovery=$recovered;verification_final=$restoreFinal;current_product_apply=$false;physical_disk_shrink=$false;automatic_retry=$false;limits=@('C18 application startup/export/RBAC not executed on original full recovery copy','C01 small fixture, all negative subcases, lock2/transaction10 and F01/F02/F03 remain separate mandatory gates','Not release/whole DISK/R3 acceptance')}
}finally{$secret=$null;$admin=$null;$envApply=$null;$envRepeat=$null}
