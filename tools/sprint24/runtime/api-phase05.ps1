param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha,[Parameter(Mandatory)][string]$Nonce)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$go=[Console]::In.ReadLineAsync();if(!$go.Wait(30000) -or $go.Result -cne ('GO '+$Nonce)){throw 'outer_job_not_admitted'}
if((Get-FileHash -LiteralPath $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if([string]$PWD -cne $c.workspace -or $c.output -cne (Join-Path $PWD '.local/sprint21/root/sprint24/api03') -or $c.pgdata -cne (Join-Path $PWD '.local/sprint21/root/pgdata11') -or $c.session_seconds -lt 1 -or $c.session_seconds -gt 1680 -or [DateTimeOffset]$c.deadline_utc -gt [DateTimeOffset]'2026-10-23T22:45:20Z' -or $c.app_sha -cne '072FB7B8ADE3C7473899424D84842477A0B96B78F5DAF2AD7F30EB05FF3E03A2'){throw 'api_scope'}
if($c.broker -cne (Join-Path $PWD 'tools/sprint24/broker.psm1') -or $c.broker_sha -cne 'D4401113F3DF23F0796B5CCEE0AB6EC6F6C2EF76476C57B949092E156DE56BEB' -or (Get-FileHash -LiteralPath $c.broker).Hash -cne $c.broker_sha){throw 'broker_pin'}
if($c.reserve_bytes -ne 201326592 -or $c.http_checker_sha -cnotmatch '^[0-9A-F]{64}$' -or $c.http_proof_status -cne 'ACTUAL_CURRENT_API_PASS'){throw 'pending_checker_or_reserve'}
if($c.recovery_proof_sha -cnotmatch '^[0-9A-F]{64}$' -or (Get-FileHash -LiteralPath $c.recovery_proof).Hash -cne $c.recovery_proof_sha){throw 'recovery_actual_gate'}
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'source_pin'}}
Import-Module $c.broker -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata
Assert-OwnedHash $c.app $c.app_sha;Assert-OwnedHash $c.http_checker $c.http_checker_sha
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'postgres_not_stopped'}
foreach($port in @(55449,3144)){$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$listener.Start()}finally{$listener.Stop()}}
$before=Assert-S22Capacity $c
if($before.root_allocation_bytes+$c.reserve_bytes -gt (10GB-512MB) -or $before.root_logical_bytes+$c.reserve_bytes -gt (10GB-512MB) -or $before.allocation_bytes+$c.reserve_bytes -gt (14GB-512MB) -or $before.logical_bytes+$c.reserve_bytes -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+$c.reserve_bytes)){throw 'api192MiB_reserve'}
Write-OwnedJson (Join-Path $c.output 'resource-before.json') $before
foreach($name in @('private','session','http-pre','http-post')){[void](New-OwnedPrivateDirectory (Join-Path $c.output $name))}
$session=Join-Path $c.output 'session'
$ready=@(1..10|ForEach-Object{'ready-'+('{0:D2}' -f $_)})
$aliases=@('source10k','app10k','app90k','child','http90k','source90k')
$wanted=@('postgres','pg-stop')+$ready+$aliases
if($c.commands.Count -ne 18){throw 'fixed_native_count'}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($cmd in $c.commands){
 if($cmd.label -cnotin $wanted -or !$seen.Add($cmd.label) -or $cmd.directory -cne $c.workspace -or $cmd.seconds -lt 1 -or $cmd.seconds -gt $c.session_seconds -or $cmd.output_limit -lt 1 -or $cmd.output_limit -gt $(if($cmd.label -in @('app10k','app90k')){1048576}else{65536})){throw 'fixed_command_scope'}
 $key=if($cmd.label -ceq 'postgres'){'postgres'}elseif($cmd.label -ceq 'pg-stop'){'pg_ctl'}elseif($cmd.label -cin $ready){'pg_isready'}elseif($cmd.label -in @('app10k','app90k')){'app'}elseif($cmd.label -in @('source10k','child')){'psql'}else{'python'}
 if($cmd.program -cne $c[$key] -or $cmd.sha256 -cne $c[$key+'_sha']){throw 'actual_program_identity'}
 if($cmd.output_limit -ne $(if($cmd.label -in @('app10k','app90k')){1048576}else{65536})){throw 'exact_per_label_capture_bound'}
 if([bool]$cmd.service -ne ($cmd.label -in @('postgres','app10k','app90k'))){throw 'service_scope'}
 if($cmd.label -in @('http90k','source90k') -and $cmd.seconds -gt 120){throw 'checker_native_bound'}
}
$worker=@{label='worker';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',$c.worker,'-TaskConfig',$Config,'-TaskConfigSha',$ConfigSha);directory=$c.workspace;environment=@{TEMP=$c.temp;TMP=$c.temp};seconds=$c.session_seconds;output_limit=65536}
$r=Invoke-S22Broker $c $worker $c.commands $session 'none'
$workerFailed=$r.records.ContainsKey('worker') -and $r.records.worker.native_exit -ne 0
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $workerFailed){
 $wf=Join-Path $c.output 'worker-failure.json';$br=Join-Path $session 'broker-result.json'
 Write-OwnedJson (Join-Path $c.output 'api-failed-phase.json') @{status='FAILED_PARTIAL_ONLY';config_sha256=$ConfigSha;broker_failure=$r.failure;stop_reason=$r.stop_reason;kill_fault=$r.kill_fault;worker_native_exit=$(if($r.records.ContainsKey('worker')){$r.records.worker.native_exit}else{$null});worker_failure_sha256=$(if(Test-Path $wf){(Get-FileHash $wf).Hash}else{$null});broker_result_sha256=$(if(Test-Path $br){(Get-FileHash $br).Hash}else{$null});missing_future_success_commands_not_primary=$true}
 throw 'primary_worker_or_broker_failure'
}
foreach($label in (@('worker','postgres','pg-stop')+$aliases)){if(!$r.records.ContainsKey($label)){throw ('missing_native_'+$label)}}
foreach($label in $r.records.Keys){$p=$r.records[$label];$allowed=if($label -cin $ready){@(0,1,2)}elseif($label -in @('app10k','app90k')){@(137)}else{@(0)};if($p.native_exit -notin $allowed -or !$p.stdout_complete -or !$p.stderr_complete -or $p.source_status -cne 'captured'){throw 'native_or_capture_failure'}}
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'pid_not_removed'}
if((Get-FileHash -LiteralPath $Config).Hash -cne $ConfigSha){throw 'config_changed'}
$after=Assert-S22Capacity $c;foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'api-phase-proof.json') @{status='ACTUAL_S24_API_PHASE_REQUIRES_INDEPENDENT_ACCEPTANCE';config_sha256=$ConfigSha;before=$before;after=$after;native_records=$r.records.Count;all_full_eof=$true;app_sha256=$c.app_sha;compiler_executed=$false;stock_server_process_started=$true;aliases_protocol_only=$true;pid_absent=$true}
