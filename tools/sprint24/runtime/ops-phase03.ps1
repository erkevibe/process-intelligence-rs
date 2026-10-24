param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha,[Parameter(Mandatory)][string]$Nonce)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$go=[Console]::In.ReadLineAsync();if(!$go.Wait(30000) -or $go.Result -cne ('GO '+$Nonce)){throw 'outer_job_not_admitted'}
if((Get-FileHash $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if([string]$PWD -cne $c.workspace -or $c.output -cne (Join-Path $PWD '.local/sprint21/root/sprint24/ops02') -or $c.pgdata -cne (Join-Path $PWD '.local/sprint21/root/pgdata11') -or $c.reserve_bytes -ne 201326592 -or $c.session_seconds -lt 1 -or $c.session_seconds -gt 1680 -or [DateTimeOffset]$c.deadline_utc -gt [DateTimeOffset]'2026-10-23T22:45:20Z'){throw 'ops_scope'}
if($c.ops_checker_sha -cnotmatch '^[0-9A-F]{64}$' -or $c.api_acceptance_sha -cnotmatch '^[0-9A-F]{64}$' -or $c.protocol_resolution_sha -cnotmatch '^[0-9A-F]{64}$'){throw 'prospective_entry_gates_pending'}
foreach($gate in @(@($c.resource_repair_qa,$c.resource_repair_qa_sha),@($c.resource_repair_td,$c.resource_repair_td_sha))){if($gate[1] -cnotmatch '^[0-9A-F]{64}$' -or (Get-FileHash -LiteralPath $gate[0]).Hash -cne $gate[1]){throw 'actual_resource_repair_acceptance_pending'}}
foreach($review in @(@($c.recovery_qa_acceptance,$c.recovery_qa_acceptance_sha),@($c.recovery_td_acceptance,$c.recovery_td_acceptance_sha))){if($review[1] -cnotmatch '^[0-9A-F]{64}$' -or (Get-FileHash -LiteralPath $review[0]).Hash -cne $review[1]){throw 'independent_recovery03_acceptance_pending'}}
if($c.recovery_proof_sha -cnotmatch '^[0-9A-F]{64}$' -or (Get-FileHash -LiteralPath $c.recovery_proof).Hash -cne $c.recovery_proof_sha){throw 'actual_recovery03_acceptance_pending'}
foreach($pin in $c.pins){if((Get-FileHash $pin.path).Hash -cne $pin.sha256){throw 'source_pin'}}
foreach($gate in @(@($c.api_acceptance,$c.api_acceptance_sha),@($c.protocol_resolution,$c.protocol_resolution_sha),@($c.broker,$c.broker_sha),@($c.ops_checker,$c.ops_checker_sha))){if((Get-FileHash $gate[0]).Hash -cne $gate[1]){throw 'entry_gate_pin'}}
Import-Module $c.broker -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata
if(Test-Path (Join-Path $c.pgdata 'postmaster.pid')){throw 'pg_not_clean_stopped'}
foreach($port in @(55449,3144,3145)){$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$l.Start()}finally{$l.Stop()}}
$before=Assert-S22Capacity $c;if($before.root_allocation_bytes+192MB -gt (10GB-512MB) -or $before.root_logical_bytes+192MB -gt (10GB-512MB) -or $before.allocation_bytes+192MB -gt (14GB-512MB) -or $before.logical_bytes+192MB -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+192MB)){throw 'ops192MiB_reserve'}
foreach($name in @('private','session','http-seed','http-lease-check','http-down','http-latched','http-restored')){[void](New-OwnedPrivateDirectory (Join-Path $c.output $name))}
if($c.commands.Count -ne 28){throw 'ops_command_count'}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($cmd in $c.commands){
 if(!$seen.Add($cmd.label) -or $cmd.directory -cne $c.workspace -or $cmd.seconds -lt 1 -or $cmd.seconds -gt 1650){throw 'ops_command_identity'}
 $key=if($cmd.label -in @('postgres-g1','postgres-g2')){'postgres'}elseif($cmd.label -in @('pg-stop-g1','pg-stop-g2')){'pg_ctl'}elseif($cmd.label -match '^ready-g[12]-0[1-5]$'){'pg_isready'}elseif($cmd.label -in @('app-live','app-duplicate','app-restarted')){'app'}elseif($cmd.label -in @('cluster-g1','cluster-g2','create-db','snapshot-before','snapshot-lease','snapshot-after')){'psql'}elseif($cmd.label -in @('http-seed','http-lease-check','http-down','http-latched','http-restored')){'python'}else{throw 'ops_label'}
 if($cmd.program -cne $c[$key] -or $cmd.sha256 -cne $c[$key+'_sha'] -or $cmd.output_limit -ne $(if($key -ceq 'app'){1048576}else{65536}) -or [bool]$cmd.service -ne ($cmd.label -in @('postgres-g1','postgres-g2','app-live','app-restarted'))){throw 'ops_program_capture_service'}
}
$worker=@{label='worker';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',$c.worker,'-TaskConfig',$Config,'-TaskConfigSha',$ConfigSha);directory=$c.workspace;environment=@{TEMP=$c.temp;TMP=$c.temp};seconds=$c.session_seconds;output_limit=65536}
$session=Join-Path $c.output 'session';$r=Invoke-S22Broker $c $worker $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or !$r.records.ContainsKey('worker') -or $r.records.worker.native_exit -ne 0){Write-OwnedJson (Join-Path $c.output 'ops-failed-phase.json') @{status='FAILED_PARTIAL_ONLY';failure=$r.failure;stop_reason=$r.stop_reason;records=$r.records};throw 'primary_ops_worker_or_broker_failure'}
$required=@('worker','postgres-g1','postgres-g2','pg-stop-g1','pg-stop-g2','cluster-g1','cluster-g2','create-db','snapshot-before','snapshot-lease','snapshot-after','app-live','app-duplicate','app-restarted','http-seed','http-lease-check','http-down','http-latched','http-restored')
foreach($label in $required){if(!$r.records.ContainsKey($label)){throw 'ops_missing_native'}}
foreach($label in $r.records.Keys){$p=$r.records[$label];$allowed=if($label -match '^ready-'){@(0,1,2)}elseif($label -in @('app-live','app-restarted')){@(137)}elseif($label -ceq 'app-duplicate'){@(1)}else{@(0)};if($p.native_exit -notin $allowed -or !$p.stdout_complete -or !$p.stderr_complete -or $p.source_status -cne 'captured'){throw 'ops_native_capture'}}
$lease=[IO.File]::ReadAllBytes((Join-Path $session 'snapshot-lease.stdout'));
$pre=[IO.File]::ReadAllBytes((Join-Path $session 'snapshot-before.stdout'));$post=[IO.File]::ReadAllBytes((Join-Path $session 'snapshot-after.stdout'));if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pre)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($lease)) -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pre)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($post))){throw 'ops_saved_business_snapshot_changed'}
if(Test-Path (Join-Path $c.pgdata 'postmaster.pid')){throw 'ops_pid_present'}
$after=Assert-S22Capacity $c;foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};if((Get-FileHash $Config).Hash -cne $ConfigSha){throw 'config_changed'}
Write-OwnedJson (Join-Path $c.output 'ops-phase-proof.json') @{status='ACTUAL_FINITE_OPS_REQUIRES_INDEPENDENT_ACCEPTANCE';config_sha256=$ConfigSha;records=$r.records;before=$before;after=$after;two_pg_generations=$true;new_product_code=$false;no_ha_claim=$true}
