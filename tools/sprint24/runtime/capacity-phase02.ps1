param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha,[Parameter(Mandatory)][string]$Nonce)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$go=[Console]::In.ReadLineAsync();if(!$go.Wait(30000) -or $go.Result -cne ('GO '+$Nonce)){throw 'outer_job_not_admitted'}
if((Get-FileHash $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if([string]$PWD -cne $c.workspace -or $c.output -cne (Join-Path $PWD '.local/sprint21/root/sprint24/capacity-diagnostic02') -or $c.pgdata -cne (Join-Path $PWD '.local/sprint21/root/pgdata11') -or $c.session_seconds -gt 600 -or $c.session_seconds -lt 1 -or $c.reserve_bytes -ne 201326592 -or [DateTimeOffset]$c.deadline_utc -gt [DateTimeOffset]'2026-10-23T22:45:20Z'){throw 'recovery_scope'}
foreach($gate in @(@($c.entry_acceptance,$c.entry_acceptance_sha),@($c.prospective_agreement,$c.prospective_agreement_sha))){if($gate[1] -cnotmatch '^[0-9A-F]{64}$' -or (Get-FileHash -LiteralPath $gate[0]).Hash -cne $gate[1]){throw 'actual_entry_or_prospective_agreement_pending'}}
foreach($gate in @(@($c.recovery_proof,$c.recovery_proof_sha),@($c.recovery_qa,$c.recovery_qa_sha),@($c.recovery_td,$c.recovery_td_sha))){if($gate[1] -cnotmatch '^[0-9A-F]{64}$' -or (Get-FileHash -LiteralPath $gate[0]).Hash -cne $gate[1]){throw 'actual_recovery04_acceptance_pending'}}
foreach($pin in $c.pins){if((Get-FileHash $pin.path).Hash -cne $pin.sha256){throw 'source_pin'}}
if($c.broker_sha -cne 'D4401113F3DF23F0796B5CCEE0AB6EC6F6C2EF76476C57B949092E156DE56BEB' -or (Get-FileHash $c.broker).Hash -cne $c.broker_sha){throw 'broker_pin'}
Import-Module $c.broker -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata
$pidpath=Join-Path $c.pgdata 'postmaster.pid';if(Test-Path -LiteralPath $pidpath){throw 'postgres_pid_present_no_recovery_here'}
foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" -OperationTimeoutSec 5)){if($p.ExecutablePath -ceq $c.postgres -or ($p.CommandLine -and $p.CommandLine.Contains($c.pgdata))){throw 'owned_pg_already_running'}}
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,55449);try{$listener.Start()}finally{$listener.Stop()}
$before=Assert-S22Capacity $c;if($before.root_allocation_bytes+192MB -gt (10GB-512MB) -or $before.root_logical_bytes+192MB -gt (10GB-512MB) -or $before.allocation_bytes+192MB -gt (14GB-512MB) -or $before.logical_bytes+192MB -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+192MB)){throw 'recovery192MiB_reserve'}
$session=New-OwnedPrivateDirectory (Join-Path $c.output 'session')
$ready=@(1..10|ForEach-Object{'ready-'+('{0:D2}' -f $_)});$aliases=@('source10k','app10k','app90k','child','http90k','source90k');$wanted=@('postgres','pg-stop','create-control','create-empty','setup-control','empty-report','unknown-report','lock-ready-01','lock-ready-02','lock-ready-03')+$ready+$aliases
if($c.commands.Count -ne 26){throw 'recovery_command_count'};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($cmd in $c.commands){$key=if($cmd.label -ceq 'postgres'){'postgres'}elseif($cmd.label -ceq 'pg-stop'){'pg_ctl'}elseif($cmd.label -cin $ready){'pg_isready'}else{'psql'};if($cmd.label -cnotin $wanted -or !$seen.Add($cmd.label) -or $cmd.program -cne $c[$key] -or $cmd.sha256 -cne $c[$key+'_sha'] -or $cmd.directory -cne $c.workspace -or $cmd.output_limit -ne 65536 -or [bool]$cmd.service -ne ($cmd.label -ceq 'postgres') -or $cmd.seconds -lt 1 -or $cmd.seconds -gt 600){throw 'recovery_command_scope'}}
$worker=@{label='worker';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',$c.worker,'-TaskConfig',$Config,'-TaskConfigSha',$ConfigSha);directory=$c.workspace;environment=@{TEMP=$c.temp;TMP=$c.temp};seconds=$c.session_seconds;output_limit=65536}
$r=Invoke-S22Broker $c $worker $c.commands $session 'none'
if($r.records.ContainsKey('worker') -and $r.records.worker.native_exit -ne 0){Write-OwnedJson (Join-Path $c.output 'primary-worker-failure.json') @{status='ACTUAL_WORKER_FAILURE_NOT_SUCCESS';native_exit=$r.records.worker.native_exit;worker_failure='worker-failure.json';broker_result='session/broker-result.json';config_sha256=$ConfigSha};throw 'primary_worker_failure'}
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit'){throw 'recovery_broker_failure'}
foreach($label in (@('worker','postgres','pg-stop')+$aliases)){if(!$r.records.ContainsKey($label)){throw 'missing_recovery_native'}}
foreach($label in $r.records.Keys){$p=$r.records[$label];$exits=if($label -cin $ready){@(0,1,2)}elseif($label -cin @('app90k','http90k','empty-report','unknown-report')){@(3)}else{@(0)};if($p.native_exit -notin $exits -or !$p.stdout_complete -or !$p.stderr_complete -or $p.source_status -cne 'captured'){throw 'recovery_native_capture'}}
if(Test-Path $pidpath){throw 'recovery_pid_still_present'}
$after=Assert-S22Capacity $c
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};if((Get-FileHash $Config).Hash -cne $ConfigSha){throw 'config_changed'}
Write-OwnedJson (Join-Path $c.output 'capacity-phase-proof.json') @{status='ACTUAL_S24_CAPACITY_DIAGNOSTIC_REQUIRES_INDEPENDENT_ACCEPTANCE';config_sha256=$ConfigSha;before=$before;after=$after;records=$r.records;pid_absent=$true;manual_pid_or_wal_delete=$false;apps_started=$false;aliases_are_explicit_psql_controls=$true;production_report_readonly=$true;control_fixture_writes_explicit=$true}
