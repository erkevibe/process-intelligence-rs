param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
foreach ($f in $c.pins) { Assert-OwnedHash $f.path $f.sha256 }
if ($c.port -ne 5463 -or $c.proxy_port -ne 5563 -or $c.source_db -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $c.restore_db -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$' -or $c.source_db -ceq $c.restore_db -or $c.mode -cnotin @('observe','hold')) { throw 'new_identity_contract' }
if ($c.mode -ceq 'hold') { Assert-OwnedHash $c.observe_review $c.observe_review_sha }
if (@(Get-NetTCPConnection -LocalPort $c.port,$c.proxy_port -ErrorAction SilentlyContinue).Count -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 3GB -or [DateTime]::UtcNow -ge [DateTime]'2026-10-12T12:30:00Z') { throw 'new_identity_admission' }
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$bin=Join-Path $pkg 'runtime/postgresql/pgsql/bin';$psql=Join-Path $bin 'psql.exe';$postgres=Join-Path $bin 'postgres.exe';$data=Join-Path $pkg '.local/pgdata'
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
$connection=@('-h','127.0.0.1','-p',[string]$c.port,'-U','pi_admin','-w');$admin=@{PGPASSWORD=$secret.admin_password}
foreach ($entry in @(@($c.source_db,'create-source'),@($c.restore_db,'create-restore'))) {
    [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d','postgres','-v','ON_ERROR_STOP=1','-c',('CREATE DATABASE '+$entry[0]+' OWNER pi_app;'))) $pkg $out $entry[1] $admin 30)
}
$archive=Join-Path $pkg '.local/empty-stock.dump'
[void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Backup','-Database',$c.source_db,'-BackupFile',$archive) $pkg $out 'stock-backup' @{} 60)
function EmptyCapture([string]$Db,[string]$Label) {
    $r=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Db,'-At','-v','ON_ERROR_STOP=1','-f',$c.capture_sql)) $pkg $out $Label $admin 30 1MB
    return @{database=$Db;sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native_exit=$r.native_exit;scope='Full public catalog and role/DB ACL projection of new empty diagnostic database; no historical data equivalence claim'}
}
$sourcePre=EmptyCapture $c.source_db 'source-pre';$restorePre=EmptyCapture $c.restore_db 'restore-pre'
$options='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c idle_in_transaction_session_timeout=10000 -c search_path=public,pg_catalog -c TimeZone=UTC -c DateStyle=ISO,YMD'
$optionsSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($options))).ToLowerInvariant()
$events=Join-Path $out 'identity-events.jsonl'
$observer=Start-OwnedCapturedProcess -Program $c.node -ProgramSha256 $c.node_sha -Arguments @($c.observer) -WorkingDirectory $pkg -OutputDirectory $out -Label 'observer' -MaxOutputBytes 1MB -Environment @{PI_OBSERVER_DATABASE=$c.source_db;PI_OBSERVER_OPTIONS_SHA=$optionsSha;PI_OBSERVER_LISTEN_PORT=[string]$c.proxy_port;PI_OBSERVER_EVIDENCE=$events;PI_OBSERVER_MODE=$c.mode}
$wait=[DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath $events) -or -not (Get-OwnedLivePrefix $events).Contains('listener_ready')) { if ($observer.Process.HasExited -or [DateTime]::UtcNow -ge $wait) { throw 'identity_observer_not_ready' };Start-Sleep -Milliseconds 100 }
$cliEnv=@{PI_DATABASE_URL="host=127.0.0.1 port=$($c.proxy_port) user=pi_admin password=$($secret.admin_password) dbname=$($c.source_db) connect_timeout=5";PI_CLEANUP_RESTORE_URL="host=127.0.0.1 port=$($c.port) user=pi_admin password=$($secret.admin_password) dbname=$($c.restore_db) connect_timeout=5";PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=(Join-Path $pkg '.local/identity.plan.json')}
$cli=Start-OwnedCapturedProcess -Program $c.cleanup_exe -ProgramSha256 $c.cleanup_sha -Arguments @('--cleanup-storage-verify') -WorkingDirectory $pkg -OutputDirectory $out -Label 'verify' -MaxOutputBytes 1MB -Environment $cliEnv
$forced=$false
if (-not $cli.Process.WaitForExit(30000)) { $forced=$true;$cli.Process.Kill($true);[void]$cli.Process.WaitForExit(10000) }
$cliProof=Complete-OwnedCapturedProcess $cli
if (-not $observer.Process.WaitForExit(10000)) { $forced=$true;$observer.Process.Kill($true);[void]$observer.Process.WaitForExit(10000) }
$observerProof=Complete-OwnedCapturedProcess $observer
$sourcePost=EmptyCapture $c.source_db 'source-post';$restorePost=EmptyCapture $c.restore_db 'restore-post'
$eventRows=@(Get-Content -LiteralPath $events | ForEach-Object { $_ | ConvertFrom-Json })
$stop=@($eventRows | Where-Object event -ceq 'stop')
$errorRows=@($eventRows | Where-Object event -ceq 'actual_server_error')
$stderr=Get-Content -LiteralPath (Join-Path $out 'verify.stderr') -Raw
$passed=-not $forced -and $cliProof.native_exit -eq 1 -and $cliProof.stdout_complete -and $cliProof.stderr_complete -and -not $cliProof.output_limit -and -not $cliProof.capture_fault -and -not $cliProof.drain_timeout -and $stderr.Contains('cleanup_storage_unavailable') -and $observerProof.native_exit -eq 0 -and $observerProof.stdout_complete -and $observerProof.stderr_complete -and -not $observerProof.output_limit -and -not $observerProof.capture_fault -and -not $observerProof.drain_timeout -and $stop.Count -eq 1 -and $sourcePre.sha256 -ceq $sourcePost.sha256 -and $restorePre.sha256 -ceq $restorePost.sha256 -and -not (Test-Path -LiteralPath $cliEnv.PI_CLEANUP_PLAN)
if ($c.mode -ceq 'observe') { $passed=$passed -and $stop[0].identity_rows -eq 1 -and $stop[0].actual_command_complete -and $stop[0].actual_post_execute_ready }
else { $passed=$passed -and $errorRows.Count -eq 1 -and $errorRows[0].sqlstate -ceq '57014' -and $errorRows[0].statement_timeout_reason_verified -and $errorRows[0].backend_pid -gt 0 -and $stop[0].actual_target_57014 -and $stop[0].identity_rows -eq 0 }
Test-OwnedPackageTree $pkg $c.manifest_sha $true
Write-OwnedJson (Join-Path $out 'identity-result.json') @{status=$(if($passed){'IDENTITY_DIAGNOSTIC_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW'}else{'FAILED_RETAINED'});mode=$c.mode;cli=$cliProof;observer=$observerProof;source_pre=$sourcePre;restore_pre=$restorePre;source_post=$sourcePost;restore_post=$restorePost;actual_server_error=$errorRows;forced_stop=$forced;options_modified=$false;sql_cpu_duration_claimed=$false;scope='Original first identity SQL extended-cycle diagnostic only; full historical SQL5 remains OPEN'}
$secret=$null;$admin=$null;$cliEnv=$null
if (-not $passed) { throw 'identity_diagnostic_failed_retained' }
