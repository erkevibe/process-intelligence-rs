param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
foreach ($f in $c.pins) { Assert-OwnedHash $f.path $f.sha256 }
Assert-OwnedHash $c.feasibility_review $c.feasibility_review_sha
$feasibility=Get-Content -LiteralPath $c.feasibility_review -Raw | ConvertFrom-Json -DateKind String
if ($feasibility.verdict -cne 'EMPTY_ORIGINAL_IDENTITY_EXTENDED_CYCLE_STATEMENT_TIMEOUT_DIAGNOSTIC_VERIFIED' -or $feasibility.sqlstate -cne '57014' -or -not $feasibility.actual_statement_timeout_reason -or [DateTimeOffset]::Parse($feasibility.completed_before_cutoff).UtcDateTime -ge [DateTime]'2026-10-12T12:30:00Z') { throw 'feasibility_before_cutoff_proof' }
$registry=Get-Content -LiteralPath $c.registry -Raw | ConvertFrom-Json
foreach ($entry in $registry.sources) { Assert-OwnedHash (Join-Path $c.workspace $entry.path) $entry.file_sha256 }
if ($c.port -ne 5463 -or $c.proxy_port -ne 5563 -or $c.source_db -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $c.restore_db -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $c.source_db -ceq $c.restore_db -or $c.mode -cnotin @('observe','hold')) { throw 'new_phase_contract' }
if($c.mode -ceq 'hold'){
    Assert-OwnedHash $c.observe_review $c.observe_review_sha
    $observed=Get-Content $c.observe_review -Raw|ConvertFrom-Json -DateKind String
    if($observed.verdict -cne 'FULL_ORIGINAL_CORPUS_OBSERVE_COMPATIBILITY_VERIFIED_NOT_SQL5_TIMEOUT' -or $observed.candidate_count -ne 10 -or $observed.candidate_binding_mismatches -ne 0 -or $observed.controller_exit -ne 0 -or $observed.target_executions -ne 1){throw 'full_observe_gate'}
}
if (@(Get-NetTCPConnection -LocalPort $c.port,$c.proxy_port -ErrorAction SilentlyContinue).Count -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 12GB -or [DateTime]::UtcNow -ge [DateTime]'2026-10-12T15:00:00Z') { throw 'new_full_phase_admission' }
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$bin=Join-Path $pkg 'runtime/postgresql/pgsql/bin'
$psql=Join-Path $bin 'psql.exe';$postgres=Join-Path $bin 'postgres.exe';$data=Join-Path $pkg '.local/pgdata'
$setup=Join-Path $pkg 'tools/setup-postgres.ps1';$backup=Join-Path $pkg 'tools/database-backup.ps1'
[void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.stdio_wrapper,'-Script',$setup,'-ScriptSha',(Get-OwnedHash $setup),'-Proof',(Join-Path $out 'bootstrap-stdio.json'),'-ArgumentsJson',(@{Port=$c.port} | ConvertTo-Json -Compress)) $pkg $out 'bootstrap' @{} 120)
$listeners=@(Get-NetTCPConnection -LocalPort $c.port -State Listen -ErrorAction Stop)
if (@($listeners.OwningProcess | Select-Object -Unique).Count -ne 1) { throw 'new_pg_listener' }
$cp=Get-CimInstance Win32_Process -Filter ('ProcessId='+$listeners[0].OwningProcess)
if ($cp.ExecutablePath -cne $postgres -or $cp.CommandLine.Length -gt 32768) { throw 'new_pg_image' }
Write-OwnedJson (Join-Path $out 'postgres-actual-argv.json') @{pid=[int]$cp.ProcessId;creation_utc=$cp.CreationDate.ToUniversalTime().ToString('o');command_line=$cp.CommandLine;image_sha256=Get-OwnedHash $postgres}
[void](Get-OwnedDatadirArgument $cp.CommandLine $data)
Wait-OwnedReadyJob @(@{name='postgres';pid=[int]$cp.ProcessId;creation_utc=$cp.CreationDate.ToUniversalTime().ToString('o')}) $out
$secret=Get-Content -LiteralPath (Join-Path $pkg '.local/postgres-private.json') -Raw | ConvertFrom-Json
$connection=@('-h','127.0.0.1','-p',[string]$c.port,'-U','pi_admin','-w')
$envAdmin=@{PGPASSWORD=$secret.admin_password}
$archive=Join-Path $pkg '.local/retained-full-c2.dump'
[IO.File]::Copy($c.original_archive,$archive,$false);Assert-OwnedHash $archive $c.original_archive_sha
[IO.File]::Copy(($c.original_archive+'.manifest.json'),($archive+'.manifest.json'),$false)
$originalManifest=Get-Content -LiteralPath ($archive+'.manifest.json') -Raw | ConvertFrom-Json
[void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-Database',$originalManifest.database,'-BackupFile',$archive,'-TargetDatabase',$c.source_db) $pkg $out 'original-restore' @{} 120)
$newArchive=Join-Path $pkg '.local/source-stock.dump'
[void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Backup','-Database',$c.source_db,'-BackupFile',$newArchive) $pkg $out 'stock-backup' @{} 120)
[void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-Database',$c.source_db,'-BackupFile',$newArchive,'-TargetDatabase',$c.restore_db) $pkg $out 'stock-restore' @{} 120)
function Capture([string]$Database,[string]$Label) {
    $r=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Database,'-At','-v','ON_ERROR_STOP=1','-f',$c.capture_sql)) $pkg $out $Label (@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000'}) 120 1GB
    if ($r.stdout_bytes_persisted -ne 614304123 -or $r.stdout_sha256 -cne '9959D3E9E746460C0C52853D139DCBCCFF37EE230907537AB437FCFE33933DA1') { throw ('whole_capture_changed_'+$Label) }
    return @{database=$Database;bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256;native_pid=$r.pid;native_exit=$r.native_exit;full_values=$true;all_tables_ledger_timestamps_sequence=$true}
}
$sourcePre=Capture $c.source_db 'source-pre';$restorePre=Capture $c.restore_db 'restore-pre'
$planBytes=[IO.File]::ReadAllBytes($c.original_plan);$plan=[Text.Encoding]::UTF8.GetString($planBytes) | ConvertFrom-Json
if ($plan.candidates.Count -ne 10) { throw 'original_plan10' }
$registry=Get-Content -LiteralPath $c.registry -Raw | ConvertFrom-Json
foreach ($entry in $registry.sources) { Assert-OwnedHash (Join-Path $c.workspace $entry.path) $entry.file_sha256 }
$simple=@{};foreach ($entry in $registry.entries) { if ($entry.admitted -and $entry.protocol -ceq 'Simple') { $simple[$entry.sql_sha256]=$entry.commands } }
$observerConfig=Join-Path $out 'observer-config.json';$events=Join-Path $out 'observer-events.jsonl'
$options='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c idle_in_transaction_session_timeout=10000 -c search_path=public,pg_catalog -c TimeZone=UTC -c DateStyle=ISO,YMD'
$optionsSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($options))).ToLowerInvariant()
Write-OwnedJson $observerConfig @{mode=$c.mode;backend_port=$c.port;listen_port=$c.proxy_port;database=$c.source_db;options_sha=$optionsSha;plan_sha=(Get-OwnedHash $c.original_plan).ToLowerInvariant();target_key_sha='36dbcb9962bae96b0ad3cb1aac7ebc959cc5f3b304a5338d4b4453df631a3585';plan_path=$c.original_plan;evidence_path=$events;allowed_parse_sha=@($registry.entries | Where-Object { $_.admitted -and $_.protocol -ceq 'Parse' } | ForEach-Object sql_sha256 | Sort-Object -Unique);allowed_simple=@($simple.Keys | Sort-Object | ForEach-Object { @{sha=$_;commands=$simple[$_]} })}
$observer=Start-OwnedCapturedProcess -Program $c.node -ProgramSha256 $c.node_sha -Arguments @($c.observer) -WorkingDirectory $pkg -OutputDirectory $out -Label 'observer' -MaxOutputBytes 1MB -Environment @{PI_FULL_OBSERVER_CONFIG=$observerConfig}
$wait=[DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath $events) -or -not (Get-OwnedLivePrefix $events).Contains('listener_ready')) { if ($observer.Process.HasExited -or [DateTime]::UtcNow -ge $wait) { throw 'observer_not_ready' };Start-Sleep -Milliseconds 100 }
$planOutput=Join-Path $pkg '.local/new-verify.plan.json'
$cliEnv=@{PI_DATABASE_URL="host=127.0.0.1 port=$($c.proxy_port) user=pi_admin password=$($secret.admin_password) dbname=$($c.source_db) connect_timeout=5";PI_CLEANUP_RESTORE_URL="host=127.0.0.1 port=$($c.port) user=pi_admin password=$($secret.admin_password) dbname=$($c.restore_db) connect_timeout=5";PI_CLEANUP_ARCHIVE=$newArchive;PI_CLEANUP_PLAN=$planOutput}
$verifyFailure=$null
$cliForced=$false
if($c.mode -ceq 'hold'){
    $command=Start-OwnedCapturedProcess -Program $c.cleanup_exe -ProgramSha256 $c.cleanup_sha -Arguments @('--cleanup-storage-verify') -WorkingDirectory $pkg -OutputDirectory $out -Label 'verify' -MaxOutputBytes 1MB -Environment $cliEnv
    $until=[DateTime]::UtcNow.AddSeconds(300)
    while(-not $command.Process.WaitForExit(100)){
        if([DateTime]::UtcNow -ge $until -or $command.OutCapture.LimitReached -or $command.ErrCapture.LimitReached -or $command.OutCapture.Pump.IsFaulted -or $command.ErrCapture.Pump.IsFaulted){$cliForced=$true;$command.Process.Kill($true);if(-not $command.Process.WaitForExit(10000)){throw 'hold_cli_stop_timeout'};break}
    }
    $cli=Complete-OwnedCapturedProcess $command
}else{try { $cli=Invoke-OwnedPhaseCommand $c.cleanup_exe $c.cleanup_sha @('--cleanup-storage-verify') $pkg $out 'verify' $cliEnv 300 1MB } catch { $verifyFailure=$_ }}
if (-not $observer.Process.WaitForExit(10000)) { $observer.Process.Kill($true);[void]$observer.Process.WaitForExit(10000);$observerStop=$true } else { $observerStop=$false }
$observerProof=Complete-OwnedCapturedProcess $observer
$sourcePost=Capture $c.source_db 'source-post';$restorePost=Capture $c.restore_db 'restore-post'
Test-OwnedPackageTree $pkg $c.manifest_sha $true
$result=@{mode=$c.mode;scope='UNCHANGED 0.7.1 full retained C2 diagnostic; NOT current-product cleanup acceptance';source_pre=$sourcePre;restore_pre=$restorePre;source_post=$sourcePost;restore_post=$restorePost;observer_native=$observerProof;observer_forced_stop=$observerStop;cli_forced_stop=$cliForced;sql_cpu_duration_claimed=$false;options_modified=$false;apply_executed=$false;status='FAILED_RETAINED'}
if ($c.mode -ceq 'observe' -and -not $verifyFailure -and -not $observerStop -and $observerProof.native_exit -eq 0 -and $observerProof.stdout_complete -and $observerProof.stderr_complete) {
    $value=Get-Content -LiteralPath (Join-Path $out 'verify.stdout') -Raw | ConvertFrom-Json
    $eventsRead=@(Get-Content -LiteralPath $events | ForEach-Object { $_ | ConvertFrom-Json })
    if ($value.outcome -cne 'cleanup_verified' -or $value.candidate_rows -ne 10 -or @($eventsRead | Where-Object kind -ceq 'actual_target_command_complete').Count -ne 1 -or @($eventsRead | Where-Object kind -ceq 'actual_target_datarow_shape').Count -ne 1) { throw 'observe_whole_result' }
    $generatedPlan=Get-Content -LiteralPath $planOutput -Raw | ConvertFrom-Json -DateKind String
    if ($generatedPlan.candidates.Count -ne 10) { throw 'generated_plan10' }
    foreach ($expected in $plan.candidates) {
        $actual=@($generatedPlan.candidates | Where-Object key -ceq $expected.key)
        if ($actual.Count -ne 1 -or $actual[0].source_version -ne $expected.source_version -or $actual[0].source_sha -cne $expected.source_sha -or $actual[0].checksum -cne $expected.checksum -or $actual[0].logical_bytes -ne $expected.logical_bytes) { throw 'whole_candidate_binding_changed' }
    }
    $result.status='OBSERVE_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW'
}
if($c.mode -ceq 'hold' -and -not $cliForced -and -not $observerStop -and $observerProof.native_exit -eq 0 -and $observerProof.stdout_complete -and $observerProof.stderr_complete -and -not $observerProof.output_limit -and -not $observerProof.capture_fault -and -not $observerProof.drain_timeout -and $cli.native_exit -eq 1 -and $cli.stdout_complete -and $cli.stderr_complete -and -not $cli.output_limit -and -not $cli.capture_fault -and -not $cli.drain_timeout){
    $eventsRead=@(Get-Content $events|ForEach-Object{$_|ConvertFrom-Json})
    $errors=@($eventsRead|Where-Object kind -ceq 'actual_server_error')
    $stops=@($eventsRead|Where-Object kind -ceq 'stop')
    $bind=@($eventsRead|Where-Object kind -ceq 'actual_target_bind_complete')
    $execute=@($eventsRead|Where-Object kind -ceq 'actual_target_original_execute')
    $stderr=Get-Content (Join-Path $out 'verify.stderr') -Raw
    if($errors.Count -ne 1 -or $errors[0].sqlstate -cne '57014' -or -not $errors[0].statement_timeout_reason_verified -or -not $errors[0].target_execution -or $errors[0].backend_pid -le 0 -or $bind.Count -ne 1 -or $bind[0].backend_pid -ne $errors[0].backend_pid -or $execute.Count -ne 1 -or $stops.Count -ne 1 -or -not $stops[0].actual_target57014 -or $stops[0].target_rows -ne 0 -or $stops[0].target_completed -or $stops[0].target_executions -ne 1 -or -not $stderr.Contains('cleanup_storage_unavailable') -or (Test-Path $planOutput)){throw 'full_hold_timeout_contract'}
    $log=Join-Path $pkg '.local/logs/postgres-server.log'
    if((Get-Item $log).Length -gt 1MB){throw 'hold_pg_log_bound'}
    $logText=Get-OwnedLivePrefix $log 1MB
    $reasonPattern='\['+[regex]::Escape([string]$errors[0].backend_pid)+'\].*ERROR:\s+canceling statement due to statement timeout'
    $matches=[regex]::Matches($logText,$reasonPattern)
    if($matches.Count -ne 1){throw 'hold_same_backend_pg_reason'}
    $result.actual_server_error=$errors[0];$result.same_backend_pg_reason_count=$matches.Count;$result.plan_absent=$true
    $result.status='HOLD_TIMEOUT_DIAGNOSTIC_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW'
}
Write-OwnedJson (Join-Path $out ('sql5-'+$c.mode+'-result.json')) $result
$secret=$null;$cliEnv=$null;$envAdmin=$null
if ($verifyFailure) { throw $verifyFailure }
if ($result.status -cnotin @('OBSERVE_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW','HOLD_TIMEOUT_DIAGNOSTIC_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW')) { throw 'observer_failed_retained' }
