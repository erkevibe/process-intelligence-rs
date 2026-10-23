param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha,[Parameter(Mandatory)][string]$Nonce)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$go=[Console]::In.ReadLineAsync();if(!$go.Wait(30000) -or $go.Result -cne ('GO '+$Nonce)){throw 'collector_outer_job_not_admitted'}
if((Get-FileHash -LiteralPath $Config).Hash -cne $ConfigSha){throw 'measurement_config_pin'}
$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if([string]$PWD -cne $c.workspace -or [DateTimeOffset]$c.deadline_utc -gt [DateTimeOffset]'2026-10-23T09:53:31Z'){throw 'measurement_scope_deadline'}
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'measurement_source_pin'}}
Import-Module (Join-Path $PSScriptRoot 'measure-broker.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata;Assert-OwnedPrivateDirectory $c.input_directory
if($c.app_sha -cne '4121BD68F1C0C05A61B039FADF20FEC5C2DA4379D8AAAFB170DC3B43861D1525' -or $c.input_manifest_sha -cne '59DA6F7A7A61826A579F93C394D1EFDF7DDEBE9D550E8120E1BB1EF8D5BDCC43'){throw 'fixed_binary_or_input_manifest'}
Assert-OwnedHash $c.app $c.app_sha;Assert-OwnedHash (Join-Path $c.input_directory 'manifest.json') $c.input_manifest_sha
Assert-OwnedHash $c.protocol_resolution $c.protocol_resolution_sha
$resolution=Get-Content -LiteralPath $c.protocol_resolution -Raw|ConvertFrom-Json -AsHashtable
if($resolution.actual_for -lt 3 -or $resolution.fixed_voters -ne 5 -or $resolution.proposal_sha256 -cne $c.protocol_sha){throw 'prospective_protocol_not_admitted'}
foreach($gate in @('mechanism_qa','mechanism_td','adapter_qa','adapter_td','resource_closure','archive_result','counterfactual_archive','counterfactual_audit')){if(!$c.ContainsKey($gate) -or !$c.ContainsKey($gate+'_sha')){throw 'actual_independent_gate_required'};Assert-OwnedHash $c[$gate] $c[$gate+'_sha']}
$resourceGate=Get-Content -LiteralPath $c.resource_closure -Raw|ConvertFrom-Json -AsHashtable
$archiveGate=Get-Content -LiteralPath $c.archive_result -Raw|ConvertFrom-Json -AsHashtable
if($resourceGate.status -cne 'ACTUAL_UNCHANGED_RESOURCE_GUARD_AFTER_VERIFIED_ARCHIVE' -or $resourceGate.guard_sha256 -cne '8EC87E1E91F07514C18B2698F5E77B35CD7A02AB8DCEEA4FF7268FB8609C3EC6' -or $archiveGate.status -cne 'BYTE_VERIFIED_STOPPED_PG02_TO10_COMPACTED'){throw 'resource_recovery_not_complete'}
$counterGate=Get-Content -LiteralPath $c.counterfactual_archive -Raw|ConvertFrom-Json -AsHashtable
$counterAudit=Get-Content -LiteralPath $c.counterfactual_audit -Raw|ConvertFrom-Json -AsHashtable
if($counterGate.status -cne 'BYTE_VERIFIED_FOUR_COUNTERFACTUAL_TREES_COMPACTED' -or $counterAudit.status -cne 'INDEPENDENT_FOUR_UNIQUE_COUNTERFACTUAL_ARCHIVES_BYTES_VERIFIED' -or $counterAudit.files -ne 21370 -or $counterAudit.expanded_bytes -ne 46285147){throw 'counterfactual_preservation_audit_required'}
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'pg_fixture_must_be_stopped'}
if($c.pgdata -cne (Join-Path $c.workspace '.local/sprint21/root/pgdata11') -or $c.database -cne 'pi_s22_complexity01' -or $c.app_port -ne 3139 -or $c.pg_port -ne 55449){throw 'measurement_exact_scope'}
if((Get-Content -LiteralPath (Join-Path $c.pgdata 'PG_VERSION') -Raw).Trim() -cne '18'){throw 'expected_owned_postgres18'}
foreach($port in @(3139,55449)){$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$probe.Start()}finally{$probe.Stop()}}
$manifest=Get-Content -LiteralPath (Join-Path $c.input_directory 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable
if(@($manifest.cases).Count -ne 2 -or $manifest.cases[0].id -cne 'CMP10K' -or $manifest.cases[0].events -ne 10000 -or $manifest.cases[1].id -cne 'CMP90K' -or $manifest.cases[1].events -ne 90000){throw 'fixed_order_counts'}
foreach($case in $manifest.cases){foreach($keys in @(@('input_file','input_sha256'),@('oracle_file','oracle_sha256'),@('manual_csv_file','manual_csv_sha256'))){Assert-OwnedHash (Join-Path $c.input_directory $case[$keys[0]]) $case[$keys[1]]}}
$before=Assert-S22Capacity $c;Write-OwnedJson (Join-Path $c.output 'resource-before.json') $before
Write-OwnedJson (Join-Path $c.output 'method-before-first-observation.json') @{protocol_sha256=$c.protocol_sha;config_sha256=$ConfigSha;input_manifest_sha256=$c.input_manifest_sha;app_sha256=$c.app_sha;order=@('CMP10K','CMP90K');observations_per_case=1;fresh_app_per_case=$true;allowed_terminal_outcomes=@('completed+independent_pair','failed+report_byte_limit+no_pair');retuning_or_repeated_submissions_allowed=$false;memory_interval_ms=50;memory_max_samples_per_app=5000;memory_max_bytes_per_app=4MB;http_case_seconds=120;http_request_seconds=15;session_seconds=$c.session_seconds;api_not_browser=$true;no_ram_cap_cpu_speedup_slo_or_graph_complexity_claim=$true}
$commands=[Collections.Generic.List[hashtable]]::new()
function Command([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int]$Seconds=30,[long]$Cap=1MB){$commands.Add(@{label=$Label;program=$Program;sha256=$Sha;arguments=$Arguments;directory=$c.workspace;environment=$Environment;seconds=$Seconds;output_limit=$Cap;service=($Label -in @('postgres','app10k','app90k'))})}
Command 'postgres' $c.postgres $c.postgres_sha @('-D',$c.pgdata,'-h','127.0.0.1','-p','55449','-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') @{} 900 8MB
for($i=1;$i -le 12;$i++){Command ('ready-'+('{0:D2}' -f $i)) $c.pg_isready $c.pg_isready_sha @('-h','127.0.0.1','-p','55449','-U','pi_s21_admin','-d','postgres','-t','1') @{} 3 65536}
$sqlEnvironment=@{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8'}
$sqlPrefix=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','55449','-U','pi_s21_admin','-w')
Command 'cluster-identity' $c.psql $c.psql_sha ($sqlPrefix+@('-d','postgres','-c',"SELECT json_build_object('data_directory',current_setting('data_directory'),'port',current_setting('port'),'database',current_database(),'user',current_user,'in_recovery',pg_is_in_recovery());")) $sqlEnvironment 15 65536
Command 'create-db' $c.psql $c.psql_sha ($sqlPrefix+@('-d','postgres','-c','CREATE DATABASE pi_s22_complexity01 OWNER pi_s21_app')) $sqlEnvironment 15
foreach($case in $manifest.cases){
 $small=$case.id -ceq 'CMP10K';$tag=if($small){'10k'}else{'90k'}
 $env=@{PI_DATABASE_URL='host=127.0.0.1 port=55449 user=pi_s21_app dbname=pi_s22_complexity01 connect_timeout=5 application_name=s22_fixed_observation';PORT='3139';RUST_LOG='info'}
 Command ('app'+$tag) $c.app $c.app_sha @() $env 240 8MB
 $httpLabel=if($small){'child'}else{'http90k'}
 Command $httpLabel $c.python $c.python_sha @('-I','-B',(Join-Path $PSScriptRoot 'measure-http.py'),'--url','http://127.0.0.1:3139','--inputs',$c.input_directory,'--output',(Join-Path $c.output ('http-'+$tag)),'--credentials',(Join-Path $c.output 'private-credentials.json'),'--case',$case.id) @{PYTHONDONTWRITEBYTECODE='1'} 125 1MB
 $sql="SELECT json_build_object('rows',(SELECT json_agg(row_to_json(r)) FROM public.pi_records r WHERE kind='conversion' AND octet_length(document->>'input')=$($case.input_bytes)),'projects',(SELECT json_agg(json_build_object('project_id',project_id,'conversions',document->'conversions')) FROM public.pi_projects));"
 $readEnv=@{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c default_transaction_read_only=on';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8'}
 Command ('source'+$tag) $c.psql $c.psql_sha ($sqlPrefix+@('-d',$c.database,'-c',$sql)) $readEnv 15 32MB
}
Command 'pg-stop' $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') @{} 15 2MB
$worker=@{label='worker';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'measure-worker.ps1'),'-MeasurementConfig',$Config,'-MeasurementConfigSha',$ConfigSha);directory=$c.workspace;environment=@{TEMP=$c.temp;TMP=$c.temp};output_limit=1MB;seconds=900}
$session=New-OwnedPrivateDirectory $c.session_output
$result=Invoke-S22Broker $c $worker $commands.ToArray() $session 'none'
if($result.failure -or $result.kill_fault -or $result.stop_reason -cne 'worker_exit'){throw 'measurement_broker_failed_saved_captures'}
foreach($required in @('worker','postgres','cluster-identity','create-db','ready-01','app10k','app90k','child','http90k','source10k','source90k','pg-stop')){if(!$result.records.ContainsKey($required)){throw ('mandatory_native_record_missing_'+$required)}}
foreach($label in $result.records.Keys){$r=$result.records[$label];$allowed=if($label -in @('app10k','app90k')){@(137)}elseif($label -like 'ready-*'){@(0,1,2)}else{@(0)};if($r.native_exit -notin $allowed -or !$r.stdout_complete -or !$r.stderr_complete -or $r.source_status -cne 'captured'){throw ('measurement_native_or_capture_failed_'+$label)}}
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'postgres_did_not_remove_own_pidfile'}
$proofPath=Join-Path $c.output 'worker-measurement-proof.json';if(!(Test-Path -LiteralPath $proofPath)){throw 'two_case_worker_proof_missing'}
$workerProof=Get-Content -LiteralPath $proofPath -Raw|ConvertFrom-Json -AsHashtable
if(@($workerProof.cases).Count -ne 2 -or $workerProof.cases[0].case_id -cne 'CMP10K' -or $workerProof.cases[1].case_id -cne 'CMP90K'){throw 'mandatory_ordered_two_cases_missing'}
$after=Assert-S22Capacity $c;foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$outputBytes=[long]0;foreach($file in [IO.DirectoryInfo]::new($c.output).EnumerateFiles('*',[IO.SearchOption]::AllDirectories)){$outputBytes+=$file.Length;if($outputBytes -gt 124MB){throw 'observed_evidence_budget_plus_final_proof_reserve_exceeded'}}
Write-OwnedJson (Join-Path $c.output 'measurement-proof.json') @{status='ROOT_OBSERVED_TWO_FIXED_TERMINAL_OBSERVATIONS_REQUIRES_INDEPENDENT_AUDIT';worker_proof_sha256=Get-OwnedHash $proofPath;broker_result_sha256=Get-OwnedHash (Join-Path $session 'broker-result.json');native_records=$result.records.Count;all_native_streams_eof=$true;before=$before;after=$after;historical_unknowns_repaired=$false;historical_unknowns=6;browser_checked=$false;postgres_stopped=$true;utc=[DateTimeOffset]::UtcNow.ToString('o')}
