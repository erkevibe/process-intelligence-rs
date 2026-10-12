param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$admitted=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($admitted.scope -cne 'full-original-delete-commit-boundary' -or $admitted.boundary_mode -cnotin @('observe-delete','f02','f03') -or $admitted.cleanup_sha -cne '7FC3812772D64D9A74EEC55413C41C6C189167FFEB279EFCE2613CA7FD6AD195' -or $admitted.mode -cne 'observe'){throw 'exact_boundary_scope'}
foreach($pin in $admitted.pins){Assert-OwnedHash $pin.path $pin.sha256}
if($admitted.boundary_mode -cne 'observe-delete'){
 Assert-OwnedHash $admitted.boundary_observe_review $admitted.boundary_observe_review_sha
 $prior=Get-Content $admitted.boundary_observe_review -Raw|ConvertFrom-Json
 if($prior.verdict -cne 'FULL_ORIGINAL_DELETE_COMMIT_OBSERVE_INDEPENDENTLY_VERIFIED'){throw 'actual_boundary_observe_gate'}
}
Assert-OwnedHash $admitted.baseline_helper $admitted.baseline_helper_sha
# Complete independently reviewed stock restore and unchanged original Verify first.
. $admitted.baseline_helper -PhaseConfig $PhaseConfig -PhaseConfigSha $PhaseConfigSha
$secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
$admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000'}
$connection=@('-h','127.0.0.1','-p',[string]$c.port,'-U','pi_admin','-w')
function State([string]$Database,[string]$Label,[string]$Sql=$c.capture_sql,[long]$Cap=1GB){
 $r=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Database,'-At','-v','ON_ERROR_STOP=1','-f',$Sql)) $pkg $out $Label $admin 120 $Cap
 return @{bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256;native_exit=$r.native_exit;database=$Database}
}
function CompleteNative($n){return ($n.stdout_complete -and $n.stderr_complete -and -not $n.output_limit -and -not $n.capture_fault -and -not $n.drain_timeout)}
try{
 $catalogPre=State $c.source_db 'boundary-catalog-pre' $c.catalog_sql 16MB
 $restoreCatalogPre=State $c.restore_db 'boundary-restore-catalog-pre' $c.catalog_sql 16MB
 $registry=Get-Content $c.boundary_registry -Raw|ConvertFrom-Json
 foreach($entry in $registry.sources){Assert-OwnedHash (Join-Path $c.workspace $entry.path) $entry.file_sha256}
 $simple=@{};foreach($entry in $registry.entries){if($entry.admitted -and $entry.protocol -ceq 'Simple'){$simple[$entry.sql_sha256]=$entry.commands}}
 $events=Join-Path $out 'boundary-events.jsonl';$observerConfig=Join-Path $out 'boundary-observer-config.json'
 Write-OwnedJson $observerConfig @{mode=$c.boundary_mode;backend_port=$c.port;listen_port=$c.proxy_port;database=$c.source_db;options_sha=$optionsSha;plan_sha=(Get-OwnedHash $planOutput).ToLowerInvariant();plan_path=$planOutput;target_key_sha='36dbcb9962bae96b0ad3cb1aac7ebc959cc5f3b304a5338d4b4453df631a3585';evidence_path=$events;allowed_parse_sha=@($registry.entries|Where-Object {$_.admitted -and $_.protocol -ceq 'Parse'}|ForEach-Object sql_sha256|Sort-Object -Unique);allowed_simple=@($simple.Keys|Sort-Object|ForEach-Object {@{sha=$_;commands=$simple[$_]}})}
 $observer=Start-OwnedCapturedProcess -Program $c.node -ProgramSha256 $c.node_sha -Arguments @($c.boundary_observer) -WorkingDirectory $pkg -OutputDirectory $out -Label 'boundary-observer' -MaxOutputBytes 1MB -Environment @{PI_FULL_OBSERVER_CONFIG=$observerConfig}
 $wait=[DateTime]::UtcNow.AddSeconds(10)
 while(-not (Test-Path $events) -or -not (Get-OwnedLivePrefix $events).Contains('listener_ready')){if($observer.Process.HasExited -or [DateTime]::UtcNow -ge $wait){throw 'boundary_listener_not_ready'};Start-Sleep -Milliseconds 100}
 $receipt=Join-Path $pkg '.local/boundary.receipt.json'
 $envApply=@{PI_DATABASE_URL="host=127.0.0.1 port=$($c.proxy_port) user=pi_admin password=$($secret.admin_password) dbname=$($c.source_db) connect_timeout=5";PI_CLEANUP_RESTORE_URL="host=127.0.0.1 port=$($c.port) user=pi_admin password=$($secret.admin_password) dbname=$($c.restore_db) connect_timeout=5";PI_CLEANUP_ARCHIVE=$newArchive;PI_CLEANUP_PLAN=$planOutput;PI_CLEANUP_CONFIRM_SHA=(Get-OwnedHash $planOutput);PI_CLEANUP_RECEIPT=$receipt}
 $command=Start-OwnedCapturedProcess -Program $c.cleanup_exe -ProgramSha256 $c.cleanup_sha -Arguments @('--cleanup-storage-apply') -WorkingDirectory $pkg -OutputDirectory $out -Label 'boundary-apply' -MaxOutputBytes 1MB -Environment $envApply
 $until=[DateTime]::UtcNow.AddSeconds(300);$forced=$false
 while(-not $command.Process.WaitForExit(100)){
  if([DateTime]::UtcNow -ge $until -or $command.OutCapture.LimitReached -or $command.ErrCapture.LimitReached -or $command.OutCapture.Pump.IsFaulted -or $command.ErrCapture.Pump.IsFaulted){$forced=$true;$command.Process.Kill($true);if(-not $command.Process.WaitForExit(10000)){throw 'boundary_cli_stop_timeout'};break}
 }
 $native=Complete-OwnedCapturedProcess $command
 $observerForced=-not $observer.Process.WaitForExit(10000)
 if($observerForced){$observer.Process.Kill($true);if(-not $observer.Process.WaitForExit(10000)){throw 'boundary_observer_stop_timeout'}}
 $observerNative=Complete-OwnedCapturedProcess $observer
 $trace=@(Get-Content $events|ForEach-Object {$_|ConvertFrom-Json})
 $backendIdentity=@($trace|Where-Object kind -ceq 'actual_backend_pid')
 if($backendIdentity.Count -ne 1 -or $backendIdentity[0].backend_pid -le 0){throw 'boundary_actual_backend_identity'}
 $backendGone=$false
 for($attempt=1;$attempt -le 10;$attempt++){
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d','postgres','-At','-v','ON_ERROR_STOP=1','-c',('SELECT count(*) FROM pg_stat_activity WHERE pid='+[string][int]$backendIdentity[0].backend_pid))) $pkg $out ('boundary-backend-gone-'+$attempt) $admin 10 1MB)
  if((Get-Content (Join-Path $out ('boundary-backend-gone-'+$attempt+'.stdout')) -Raw).Trim() -ceq '0'){$backendGone=$true;break}
  Start-Sleep -Milliseconds 100
 }
 if(-not $backendGone){throw 'boundary_backend_still_present_no_state_credit'}
 $sourceAfter=State $c.source_db 'boundary-source-post';$restoreAfter=State $c.restore_db 'boundary-restore-post'
 $catalogPost=State $c.source_db 'boundary-catalog-post' $c.catalog_sql 16MB
 $restoreCatalogPost=State $c.restore_db 'boundary-restore-catalog-post' $c.catalog_sql 16MB
 $deleted=@($trace|Where-Object kind -ceq 'actual_delete_command_complete')
 $pairs=@($trace|Where-Object kind -ceq 'actual_delete_returned_pair')
 $stop=@($trace|Where-Object kind -ceq 'stop')
 $outcome=$null;try{$outcome=Get-Content (Join-Path $out 'boundary-apply.stdout') -Raw|ConvertFrom-Json}catch{}
 $pre='9959D3E9E746460C0C52853D139DCBCCFF37EE230907537AB437FCFE33933DA1';$post='4F3055304BF6B6B3CAFFD7C5D9EE8D7E3C021AE031B03D36B5A3981EB77DE256'
 $classification=if($sourceAfter.sha256 -ceq $pre){'COMPLETE_PRE'}elseif($sourceAfter.sha256 -ceq $post){'EXPECTED_POST'}else{'UNEXPECTED_STOP'}
 $common=-not $forced -and -not $observerForced -and (CompleteNative $native) -and (CompleteNative $observerNative) -and $observerNative.native_exit -eq 0 -and $deleted.Count -eq 1 -and $deleted[0].actual_tag -ceq 'DELETE 10' -and $pairs.Count -eq 10 -and @($pairs.key_sha|Sort-Object -Unique).Count -eq 10 -and $stop.Count -eq 1 -and $restoreAfter.sha256 -ceq $pre -and $catalogPre.sha256 -ceq $catalogPost.sha256 -and $restoreCatalogPre.sha256 -ceq $restoreCatalogPost.sha256
 $modePassed=$false
 if($c.boundary_mode -ceq 'observe-delete'){$modePassed=$native.native_exit -eq 0 -and $outcome.outcome -ceq 'cleanup_committed' -and $outcome.deleted_rows -eq 10 -and $classification -ceq 'EXPECTED_POST' -and @( $trace|Where-Object kind -ceq 'actual_final_commit_complete').Count -eq 1 -and (Test-Path $receipt)}
 elseif($c.boundary_mode -ceq 'f02'){$modePassed=$native.native_exit -eq 3 -and $outcome.outcome -ceq 'cleanup_outcome_unconfirmed' -and $outcome.automatic_retry -eq $false -and $classification -ceq 'COMPLETE_PRE' -and $stop[0].reason -ceq 'f02_before_commit_connection_drop' -and @( $trace|Where-Object kind -ceq 'f02_original_commit_never_forwarded').Count -eq 1 -and -not (Test-Path $receipt)}
 elseif($c.boundary_mode -ceq 'f03'){$modePassed=$native.native_exit -eq 3 -and $outcome.outcome -ceq 'cleanup_outcome_unconfirmed' -and $outcome.automatic_retry -eq $false -and $classification -ceq 'EXPECTED_POST' -and $stop[0].reason -ceq 'f03_after_commit_ack_connection_drop' -and @( $trace|Where-Object kind -ceq 'f03_actual_server_commit_ack_withheld').Count -eq 1 -and @( $trace|Where-Object {$_.kind -ceq 'actual_complete_server_commit_frame_held' -and $_.client_bytes_forwarded -eq 0}).Count -eq 1 -and -not (Test-Path $receipt)}
 $passed=$common -and $modePassed
 Write-OwnedJson (Join-Path $out 'boundary-result.json') @{status=$(if($passed){'FINITE_BOUNDARY_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW'}else{'FAILED_RETAINED'});mode=$c.boundary_mode;native=$native;observer_native=$observerNative;forced=$forced;observer_forced=$observerForced;source_classification=$classification;source_post=$sourceAfter;restore_post=$restoreAfter;source_catalog_pre=$catalogPre;source_catalog_post=$catalogPost;restore_catalog_pre=$restoreCatalogPre;restore_catalog_post=$restoreCatalogPost;outcome=$outcome;receipt_present=(Test-Path $receipt);automatic_retry=$false;limits=@('Unchanged old0.7.1 diagnostic only; current0.7.2 cleanup remains disabled','Direct read-only full state reconciliation is separate from CLI internal reconciliation','No F01, full C01-C18/R3/DISK acceptance or physical shrink')}
 if(-not $passed){throw 'boundary_failed_retained_no_retry'}
 Test-OwnedPackageTree $pkg $c.manifest_sha $true
}finally{$secret=$null;$admin=$null;$envApply=$null}
