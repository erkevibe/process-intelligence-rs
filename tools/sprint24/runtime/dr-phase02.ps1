param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha,[Parameter(Mandatory)][string]$Nonce)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$go=[Console]::In.ReadLineAsync();if(!$go.Wait(30000) -or $go.Result -cne ('GO '+$Nonce)){throw 'outer_job_not_admitted'}
if((Get-FileHash -LiteralPath $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($c.status -cne 'FINAL_REVIEW_REQUIRED' -or $c.pending_admission -or [string]$PWD -cne $c.workspace -or $c.output -cne (Join-Path $PWD '.local/sprint21/root/sprint24/current-compact-dr03') -or $c.database -cne 'pi_s24_compact_dr01' -or $c.source_database -cne 'pi_s23_compat01' -or $c.session_seconds -gt 1800 -or $c.session_seconds -lt 1 -or $c.reserve_bytes -ne 640MB -or [DateTimeOffset]$c.deadline_utc -gt [DateTimeOffset]'2026-10-23T20:33:12Z' -or [DateTimeOffset]::UtcNow.AddSeconds(120) -ge [DateTimeOffset]$c.deadline_utc){throw 'dr_scope_or_pending'}
foreach($pin in $c.pins){if($pin.sha256 -cnotmatch '^[0-9A-F]{64}$' -or (Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'source_pin'}}
if($c.broker_sha -cne 'D4401113F3DF23F0796B5CCEE0AB6EC6F6C2EF76476C57B949092E156DE56BEB' -or (Get-FileHash $c.broker).Hash -cne $c.broker_sha){throw 'broker_pin'}
Import-Module $c.broker -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata
if([IO.Path]::GetFullPath($c.pgdata) -cne (Join-Path $PWD '.local/sprint21/root/pgdata11') -or [IO.Path]::GetFullPath($c.app) -cne (Join-Path $PWD '.local/sprint21/root/target/debug/process-intelligence-rs.exe')){throw 'dr_fixed_owned_paths'}
$ownedApp=[IO.Path]::GetFullPath($c.app)
$runningOwnedApps=@(Get-CimInstance Win32_Process -Filter "Name='process-intelligence-rs.exe'" -OperationTimeoutSec 5 | Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath).Equals($ownedApp,[StringComparison]::OrdinalIgnoreCase) })
if($runningOwnedApps.Count -ne 0){throw 'dr_owned_app_present_no_kill'}
Write-OwnedJson (Join-Path $c.output 'owned-app-quiescence.json') @{status='ACTUAL_FIXED_OWNED_APP_IMAGE_ABSENT_BEFORE_PG';image=$ownedApp;observed_utc=[DateTimeOffset]::UtcNow.ToString('o');count=0;scope='Non-atomic fixed owned image snapshot; no unrelated process claim or mutation'}
. $c.recovery_guard; Assert-DRKnownStalePostgres $c
foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" -OperationTimeoutSec 5)){if($p.ExecutablePath -ceq $c.postgres -or ($p.CommandLine -and $p.CommandLine.Contains($c.pgdata))){throw 'owned_pg_already_running'}}
foreach($port in @(55449,3146)){$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$listener.Start()}finally{$listener.Stop()}}
$before=Assert-S22Capacity $c
if($before.root_allocation_bytes+640MB -gt (10GB-512MB) -or $before.root_logical_bytes+640MB -gt (10GB-512MB) -or $before.allocation_bytes+640MB -gt (14GB-512MB) -or $before.logical_bytes+640MB -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+640MB)){throw 'dr640MiB_reserve'}
$session=New-OwnedPrivateDirectory (Join-Path $c.output 'session');[void](New-OwnedPrivateDirectory (Join-Path $c.output 'http-restored'))
$ready=@(1..10|ForEach-Object{'ready-'+('{0:D2}' -f $_)})
$aliases=@('source10k','app10k','app90k','child','http90k','source90k')
$extra=@('source-cohort','dump-current','list-current','create-target','restore-current','app-restored','target-after','target-cohort','check-cohort','compare-pre','compare-all','audit-current','audit-legacy')
$wanted=@('postgres','pg-stop')+$ready+$aliases+$extra
if($c.commands.Count -ne 31){throw 'dr_command_count'}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$verifiedPrograms=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($cmd in $c.commands){
 $key=if($cmd.label -ceq 'postgres'){'postgres'}elseif($cmd.label -ceq 'pg-stop'){'pg_ctl'}elseif($cmd.label -cin $ready){'pg_isready'}elseif($cmd.label -ceq 'app-restored'){'app'}elseif($cmd.label -ceq 'dump-current'){'pg_dump'}elseif($cmd.label -cin @('list-current','restore-current')){'pg_restore'}elseif($cmd.label -cin @('http90k','check-cohort','compare-pre','compare-all','audit-current','audit-legacy')){'python'}else{'psql'}
 $cap=if($cmd.label -ceq 'app-restored'){1MB}elseif($cmd.label -cin @('app10k','app90k','child','source90k','target-after')){2MB}else{65536}
 if($cmd.label -cnotin $wanted -or !$seen.Add($cmd.label) -or $cmd.program -cne $c[$key] -or $cmd.sha256 -cnotmatch '^[0-9A-F]{64}$' -or $cmd.sha256 -cne $c[$key+'_sha'] -or $cmd.directory -cne $c.workspace -or $cmd.output_limit -ne $cap -or [bool]$cmd.service -ne ($cmd.label -cin @('postgres','app-restored')) -or $cmd.seconds -lt 1 -or $cmd.seconds -gt $c.session_seconds){throw 'dr_command_scope'}
 if($verifiedPrograms.Add([IO.Path]::GetFullPath($cmd.program))){Assert-OwnedHash $cmd.program $cmd.sha256}
 if($cmd.label -ceq 'app-restored' -and ($cmd.environment.PORT -cne '3146' -or $cmd.environment.PI_DATABASE_URL -cne 'host=127.0.0.1 port=55449 user=pi_s21_app dbname=pi_s24_compact_dr01 connect_timeout=3 application_name=pi_s24_compact_dr' -or $cmd.arguments.Count -ne 0)){throw 'target_app_environment'}
}
$worker=@{label='worker';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',$c.worker,'-TaskConfig',$Config,'-TaskConfigSha',$ConfigSha);directory=$c.workspace;environment=@{TEMP=$c.temp;TMP=$c.temp};seconds=$c.session_seconds;output_limit=65536}
$r=Invoke-S22Broker $c $worker $c.commands $session 'none'
if($r.records.ContainsKey('worker') -and $r.records.worker.native_exit -ne 0){Write-OwnedJson (Join-Path $c.output 'primary-worker-failure.json') @{status='ACTUAL_WORKER_FAILURE_NOT_SUCCESS';native_exit=$r.records.worker.native_exit;worker_failure='worker-failure.json';broker_result='session/broker-result.json';config_sha256=$ConfigSha};throw 'primary_worker_failure'}
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit'){throw 'dr_broker_failure'}
foreach($label in (@('worker','postgres','pg-stop')+$aliases+$extra)){if(!$r.records.ContainsKey($label)){throw ('missing_dr_native_'+$label)}}
foreach($label in $r.records.Keys){$p=$r.records[$label];$allowed=if($label -cin $ready){@(0,1,2)}elseif($label -ceq 'app-restored'){@(137)}else{@(0)};if($p.native_exit -notin $allowed -or !$p.stdout_complete -or !$p.stderr_complete -or $p.source_status -cne 'captured'){throw 'dr_native_capture'}}
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'dr_pid_still_present'}
$after=Assert-S22Capacity $c
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Assert-OwnedHash $Config $ConfigSha
Write-OwnedJson (Join-Path $c.output 'dr-phase-proof.json') @{status='ACTUAL_CURRENT_COMPACT_DATABASE_RESTORE_REQUIRES_INDEPENDENT_ACCEPTANCE';config_sha256=$ConfigSha;before=$before;after=$after;records=$r.records;pid_absent=$true;no_compiler=$true;source_database_readonly=$true;full_database_not_cluster_backup=$true;legacy_aliases_are_protocol_only=$true}
