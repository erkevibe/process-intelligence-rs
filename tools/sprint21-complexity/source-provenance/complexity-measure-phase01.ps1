param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# PRIVATE SOURCE-ONLY DRAFT. CAP delivery and fresh Council are still prerequisites.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'complexity_measure_config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($module in @('owned-runtime.psm1','owned-phase-support.psm1','process-identity.psm1')){Import-Module (Join-Path $c.workspace ('tools/sprint21/'+$module)) -Force -DisableNameChecking}
Import-Module (Join-Path $c.workspace 'tools/sprint20/measured-runtime.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
if(!$c.ContainsKey('execution_authorized_by_fresh_council') -or $c.execution_authorized_by_fresh_council -ne $true){throw 'complexity_draft_execution_not_admitted'}
Assert-OwnedHash $c.cap_gate_receipt $c.cap_gate_receipt_sha;Assert-OwnedHash $c.fresh_council_receipt $c.fresh_council_receipt_sha
$stageStart=[DateTimeOffset]::Parse([string]$c.stage_started_utc,[Globalization.CultureInfo]::InvariantCulture)
$gate=[DateTimeOffset]::Parse([string]$c.cap_gate_completed_utc,[Globalization.CultureInfo]::InvariantCulture)
if($gate -gt [DateTimeOffset]'2026-10-22T22:30:00Z' -or $stageStart -lt $gate -or [DateTimeOffset]::UtcNow -lt $stageStart){throw 'complexity_fresh_stage_entry_gate'}
$freeze=[DateTimeOffset]'2026-10-23T00:30:37Z';$until=$stageStart.AddMinutes(20);if($until -gt $freeze){$until=$freeze}
$root=Join-Path $c.workspace '.local/sprint21/root'
if($c.output -cne (Join-Path $root 'complexity-measure01') -or $c.pgdata -cne (Join-Path $root 'pgdata11') -or $c.pg_port -ne 55449 -or $c.app_port -ne 3139 -or $c.database -cne 'pi_s21_complexity01' -or $c.input_directory -cne (Join-Path $root 'complexity-inputs01') -or $c.http_helper -cne (Join-Path $root 'complexity-http01.py')){throw 'complexity_measure_exact_scope'}
if($c.app_sha -cne '4121BD68F1C0C05A61B039FADF20FEC5C2DA4379D8AAAFB170DC3B43861D1525'){throw 'complexity_immutable_app_identity'}
Assert-OwnedHash $c.app $c.app_sha;Assert-OwnedHash $c.http_helper $c.http_helper_sha
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata;Assert-OwnedPrivateDirectory $c.input_directory
if((Get-Content -LiteralPath (Join-Path $c.pgdata 'PG_VERSION') -Raw).Trim() -cne '18'){throw 'complexity_expected_owned_pg18'}
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'complexity_cluster_not_stopped'}
if([IntPtr]::Size -ne 8 -or ([PiS20MeasuredJob]::StructureSizes() -join ',') -cne '64,144,48,80'){throw 'complexity_memory_abi'}
$manifestPath=Join-Path $c.input_directory 'manifest.json';Assert-OwnedHash $manifestPath $c.input_manifest_sha
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($manifest.status -cne 'PROSPECTIVE_INPUTS_FROZEN_BEFORE_MEASUREMENT' -or $manifest.app_sha256 -cne $c.app_sha -or !$manifest.no_converter_invoked -or @($manifest.cases).Count -ne 2 -or $manifest.cases[0].id -cne 'CMP10K' -or $manifest.cases[0].events -ne 10000 -or $manifest.cases[1].id -cne 'CMP90K' -or $manifest.cases[1].events -ne 90000){throw 'complexity_fixed_prospective_cases'}
foreach($case in $manifest.cases){
 foreach($item in @(@('input_file','input_sha256'),@('oracle_file','oracle_sha256'),@('manual_csv_file','manual_csv_sha256'))){
  $file=[string]$case[$item[0]]
  if($file -cnotin @(($case.id+'.xes'),($case.id+'-oracle.json'),($case.id+'.expected-lf.csv'))){throw 'complexity_input_filename'}
  $expectedFileSha=[string]$case[$item[1]]
  Assert-OwnedHash (Join-Path $c.input_directory $file) $expectedFileSha
 }
 if($case.input_bytes -gt 20MB -or (Get-Item -LiteralPath (Join-Path $c.input_directory $case.input_file)).Length -ne $case.input_bytes){throw 'complexity_input_byte_bound'}
}
foreach($port in @(55449,3139)){$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$probe.Start()}finally{$probe.Stop()}}
$script:pg=$null;$script:pgClosed=$false;$script:app=$null;$script:appClosed=$true;$script:appJob=$null;$script:caseUntil=$until;$script:appUntil=$until
$pgJob=[PiOwnedJob]::new();$success=$false;$allResults=[Collections.Generic.List[object]]::new();$script:activeNative=$null;$activeLane=$null
function Bounds {
 if([DateTimeOffset]::UtcNow -ge $until -or [DateTimeOffset]::UtcNow -ge $freeze -or (Get-PSDrive C).Free -lt 8GB){throw 'complexity_measure_time_or_free_floor'}
 if($script:pg -and !$script:pgClosed){if($script:pg.Process.HasExited -or $script:pg.OutCapture.LimitReached -or $script:pg.ErrCapture.LimitReached -or $script:pg.OutCapture.Pump.IsFaulted -or $script:pg.ErrCapture.Pump.IsFaulted){throw 'complexity_measure_pg_exit_or_capture'}}
 if($script:app -and !$script:appClosed){if([DateTimeOffset]::UtcNow -ge $script:appUntil -or $script:app.Process.HasExited -or $script:app.OutCapture.LimitReached -or $script:app.ErrCapture.LimitReached -or $script:app.OutCapture.Pump.IsFaulted -or $script:app.ErrCapture.Pump.IsFaulted){throw 'complexity_measure_app_exit_time_or_capture'}}
}
function Identity($Child,[string]$Program,[bool]$Pg=$false){
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Child.Process.Id)
 Assert-S21ProcessIdentity $Child $Program $row
 if($Pg){[void](Get-OwnedDatadirArgument ([string]$row.CommandLine) $c.pgdata)}
}
function Complete-Checked($Child,[bool]$Zero){
 $r=Complete-OwnedCapturedProcess $Child
 if(($Zero -and $r.native_exit -ne 0) -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'complexity_measure_native_exit_or_full_capture'}
 return $r
}
function Sample([string]$Stage,[DateTimeOffset]$PhaseStart){
 Bounds
 if(!$script:app -or $script:appClosed){throw 'complexity_measure_sample_without_live_owned_app'}
 $memory=Get-S20MeasuredProcessMemory $script:app.Handle
 return @{utc=[DateTimeOffset]::UtcNow.ToString('o');phase_elapsed_ms=([DateTimeOffset]::UtcNow-$PhaseStart).TotalMilliseconds;stage=$Stage;pid=$script:app.Record.pid;native_creation_utc=$script:app.Record.native_creation_utc;counters=$memory}
}
function IdleSamples($Samples,[string]$Stage,[DateTimeOffset]$PhaseStart){
 $end=[DateTimeOffset]::UtcNow.AddSeconds(1)
 while([DateTimeOffset]::UtcNow -lt $end){$Samples.Add((Sample $Stage $PhaseStart));Start-Sleep -Milliseconds 50}
}
function Native([string]$Program,[string]$Sha,[string[]]$Arguments,[string]$Label,[hashtable]$Environment=@{},[int]$Seconds=120,[bool]$Measure=$false,[int[]]$AllowedExits=@(0),[long]$Cap=4MB){
 Bounds
 $phaseStart=[DateTimeOffset]::UtcNow;$samples=[Collections.Generic.List[object]]::new();$native=$null;$closed=$false;$commandJob=[PiOwnedJob]::new();$fault=''
 try{
  if($Measure){IdleSamples $samples 'warm_before' $phaseStart}
  $native=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label $Label -MaxOutputBytes $Cap -Environment $Environment
  $script:activeNative=$native;$commandJob.Assign($native.Handle);if(!$commandJob.Member($native.Handle)){throw 'complexity_measure_native_job'}
  $end=[DateTimeOffset]::UtcNow.AddSeconds($Seconds);$next=[DateTimeOffset]::UtcNow
  while(!$native.Process.WaitForExit(10)){
   Bounds
   if([DateTimeOffset]::UtcNow -ge $end){$fault='native_timeout'}
   if($native.OutCapture.LimitReached -or $native.ErrCapture.LimitReached -or $native.OutCapture.Pump.IsFaulted -or $native.ErrCapture.Pump.IsFaulted){$fault='native_capture_fault'}
   if($fault){throw $fault}
   if($Measure -and [DateTimeOffset]::UtcNow -ge $next){$samples.Add((Sample 'during_http_child' $phaseStart));if($samples.Count -gt 6000){throw 'complexity_measure_sample_count'};$next=[DateTimeOffset]::UtcNow.AddMilliseconds(50)}
  }
  if($Measure){$samples.Add((Sample 'http_child_exited' $phaseStart))}
  $r=Complete-Checked $native $false;$closed=$true;$script:activeNative=$null
  if($r.native_exit -notin $AllowedExits){throw 'complexity_measure_unexpected_native_exit'}
  if($Measure){IdleSamples $samples 'after_http' $phaseStart}
  return $r
 }finally{
  try{
   if($native -and !$closed){if(!$native.Process.HasExited){$commandJob.Stop()};if($native.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $native);$closed=$true}else{throw 'complexity_measure_owned_child_stop_timeout'}}
  }finally{
   $script:activeNative=$null;$commandJob.Dispose()
   if($Measure){
    Write-OwnedJson (Join-Path $c.output ($Label+'-memory-samples.json')) @{samples=$samples.ToArray();intended_poll_ms=50;sampling_not_continuous=$true;native_peak_scope='Server process lifetime since creation; includes startup, setup and preceding phases of this same process; not per-operation exclusive.';scope='Owned server process only; excludes PostgreSQL, Python helper and Root; working set includes shared pages, private commit is distinct; no hard RAM limit or SLO established.'}
   }
  }
 }
}
function Sql([string]$Label,[string]$Statement){
 return Native $c.psql $c.psql_sha @('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_s21_admin','-w','-d','postgres','-c',$Statement) $Label @{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8'} 15
}
function WaitPg {
 $readyEnd=[DateTimeOffset]::UtcNow.AddSeconds(20)
 for($attempt=1;$attempt -le 12;$attempt++){
  Bounds;if([DateTimeOffset]::UtcNow -ge $readyEnd){throw 'complexity_measure_pg_ready_deadline'}
  $r=Native $c.pg_isready $c.pg_isready_sha @('-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_s21_admin','-d','postgres','-t','1') ('pg-readiness-'+('{0:D2}' -f $attempt)) @{} 3 $false @(0,1,2) 64KB
  if($r.native_exit -eq 0){return};Start-Sleep -Milliseconds 200
 }
 throw 'complexity_measure_pg_ready_attempt_limit'
}
function StartApp($Lane,[string]$Suffix){
 Bounds
 if(!$script:appClosed){throw 'complexity_measure_app_already_live'}
 Identity $script:pg $c.postgres $true
 $script:appJob=[PiOwnedJob]::new()
 $script:app=Start-OwnedCapturedProcess -Program $Lane.app -ProgramSha256 $Lane.app_sha -Arguments @() -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label ($Lane.name+'-app-'+$Suffix) -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL="host=127.0.0.1 port=$($c.pg_port) user=pi_s21_app dbname=$($Lane.database) connect_timeout=5 application_name=s21_complexity_measure";PORT='3139';RUST_LOG='info'}
 $script:appClosed=$false;$script:appUntil=$script:caseUntil;$script:appJob.Assign($script:app.Handle)
 if(!$script:appJob.Member($script:app.Handle)){throw 'complexity_measure_app_job'}
 $http=[Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{UseProxy=$false;AllowAutoRedirect=$false});$http.Timeout=[TimeSpan]::FromSeconds(2)
 try{
  $ready=$false;$healthEnd=[DateTimeOffset]::UtcNow.AddSeconds(30)
  while([DateTimeOffset]::UtcNow -lt $healthEnd){
   Bounds;$response=$null
   try{$response=$http.GetAsync('http://127.0.0.1:3139/health').GetAwaiter().GetResult();if([int]$response.StatusCode -eq 200){$body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if($body.Length -gt 4096){throw 'complexity_measure_health_cap'};$health=$body|ConvertFrom-Json -AsHashtable;if($health.status -cne 'ready' -or $health.version -cne $Lane.expected_version){throw 'complexity_measure_actual_binary_version'};$ready=$true;break}}catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}finally{if($response){$response.Dispose()}}
   Start-Sleep -Milliseconds 100
  }
  if(!$ready){throw 'complexity_measure_app_health_timeout'}
 }finally{$http.Dispose()}
 Identity $script:app $Lane.app
 Write-OwnedJson (Join-Path $c.output ($Lane.name+'-app-'+$Suffix+'-ready.json')) @{lane=$Lane.name;expected_version=$Lane.expected_version;actual_health=$health;pid=$script:app.Record.pid;native_creation_utc=$script:app.Record.native_creation_utc;app_sha256=$Lane.app_sha;native_lifetime_counters=Get-S20MeasuredProcessMemory $script:app.Handle}
}
function StopApp($Lane,[string]$Label){
 if(!$script:app -or $script:appClosed){return}
 $terminalMemory=$null
 if(!$script:app.Process.HasExited){Identity $script:app $Lane.app;$terminalMemory=Get-S20MeasuredProcessMemory $script:app.Handle;$script:appJob.Stop()}
 if(!$script:app.Process.WaitForExit(10000)){throw 'complexity_measure_app_stop_timeout'}
 $r=Complete-Checked $script:app $false;$script:appClosed=$true;$script:appJob.Dispose();$script:appJob=$null
 Write-OwnedJson (Join-Path $c.output ($Label+'-stop.json')) @{controlled_forced_stop=$true;clean_shutdown_not_claimed=$true;native_exit=$r.native_exit;pid=$r.pid;native_creation_utc=$r.native_creation_utc;full_streams_eof=$true;last_pre_stop_lifetime_counters=$terminalMemory;lifetime_counter_scope='Since process creation through this last pre-stop observation; excludes later teardown.'}
}
try{
 Write-OwnedJson (Join-Path $c.output 'method-before-first-measurement.json') @{status='PINNED_BEFORE_FIRST_CASE';input_manifest_sha256=$c.input_manifest_sha;prepare_source_sha256=$manifest.generator_source_sha256;measurement_source_sha256=Get-OwnedHash $PSCommandPath;http_helper_sha256=$c.http_helper_sha;app_sha256=$c.app_sha;settings_and_source_pins_bound_by_config_sha256=$PhaseConfigSha;fixed_case_ids=@('CMP10K','CMP90K');events=@(10000,90000);native_stage_end_utc=$until.ToUniversalTime().ToString('o');one_fresh_app_per_case=$true;one_conversion_per_case=$true;schema_and_product_unchanged=$true;scope='Repeated identical event count and fixed fields, not activity diversity, ordering sensitivity or graph/miner complexity.'}
 $script:pg=Start-OwnedCapturedProcess -Program $c.postgres -ProgramSha256 $c.postgres_sha -Arguments @('-D',$c.pgdata,'-h','127.0.0.1','-p','55449','-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'postgres' -MaxOutputBytes 8MB
 $pgJob.Assign($script:pg.Handle);if(!$pgJob.Member($script:pg.Handle)){throw 'complexity_pg_job'}
 WaitPg;Identity $script:pg $c.postgres $true
 [void](Sql 'sql-owned-cluster' "SELECT json_build_object('data_directory',current_setting('data_directory'),'database',current_database(),'user',current_user,'in_recovery',pg_is_in_recovery(),'port',inet_server_port())")
 $cluster=Get-Content -LiteralPath (Join-Path $c.output 'sql-owned-cluster.stdout') -Raw|ConvertFrom-Json -AsHashtable
 if($cluster.database -cne 'postgres' -or $cluster.user -cne 'pi_s21_admin' -or $cluster.in_recovery -ne $false -or $cluster.port -ne 55449 -or !([IO.Path]::GetFullPath([string]$cluster.data_directory)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'complexity_actual_cluster_identity'}
 [void](Sql 'create-one-fresh-complexity-database' 'CREATE DATABASE pi_s21_complexity01 OWNER pi_s21_app')
 $credentials=Join-Path $c.output 'complexity-private-credentials.json'
 foreach($case in $manifest.cases){
  Bounds
  $script:caseUntil=[DateTimeOffset]::UtcNow.AddSeconds(120)
  if($script:caseUntil -gt $until){throw 'complexity_insufficient_remaining_full_case_budget'}
  $name=([string]$case.id).ToLowerInvariant()
  $activeLane=@{name=$name;database=$c.database;app=$c.app;app_sha=$c.app_sha;expected_version='0.8.1'}
  StartApp $activeLane 'only-process'
  Assert-OwnedHash $manifestPath $c.input_manifest_sha
  $helperOutput=Join-Path $c.output ($name+'-http')
  [void](Native $c.python $c.python_sha @('-I','-B',$c.http_helper,'--url','http://127.0.0.1:3139','--inputs',$c.input_directory,'--output',$helperOutput,'--credentials',$credentials,'--case',[string]$case.id) ($name+'-one-conversion') @{PYTHONDONTWRITEBYTECODE='1'} 120 $true)
  $resultPath=Join-Path $helperOutput 'result.json'
  if(!(Test-Path -LiteralPath $resultPath) -or (Get-Item -LiteralPath $resultPath).Length -gt 4MB){throw 'complexity_http_result_missing_or_oversized'}
  $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
  if($result.ContainsKey('project_id') -and $result.ContainsKey('job_id') -and $result.ContainsKey('artifact_id') -and $result.project_id -and $result.job_id -and $result.artifact_id){
   if([string]$result.project_id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or [string]$result.job_id -cnotmatch '^job-[0-9]{1,32}$' -or [string]$result.artifact_id -cnotmatch '^conversion-[0-9]{1,32}$'){throw 'complexity_source_query_actual_id_shape'}
   $project=[string]$result.project_id;$job=[string]$result.job_id;$artifact=[string]$result.artifact_id
   $sql="SELECT json_build_object('metadata',(SELECT document->'conversions'->'$job' FROM public.pi_projects WHERE project_id='$project'),'record',(SELECT row_to_json(r) FROM public.pi_records r WHERE project_id='$project' AND kind='conversion' AND resource_id='$artifact'));"
   $argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','55449','-U','pi_s21_admin','-w','-d',$c.database,'-c',$sql)
   [void](Native $c.psql $c.psql_sha $argv ($name+'-retained-source-readonly') @{PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c default_transaction_read_only=on';PGCONNECT_TIMEOUT='5';PGCLIENTENCODING='UTF8'} 15 $false @(0) 25MB)
   $rawPath=Join-Path $c.output ($name+'-retained-source-readonly.stdout')
   $saved=Get-Content -LiteralPath $rawPath -Raw|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
   if(!$saved.metadata -or !$saved.record -or $saved.metadata.snapshot.id -cne $job -or $saved.metadata.artifact_id -cne $artifact -or $saved.record.resource_id -cne $artifact -or $saved.record.kind -cne 'conversion'){throw 'complexity_actual_retained_record_identity'}
   $bytes=[Text.UTF8Encoding]::new($false).GetBytes([string]$saved.record.document.input)
   $sourceSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
   if($sourceSha -cne $case.input_sha256 -or $bytes.Length -ne $case.input_bytes -or ([string]$saved.metadata.source_sha256).ToUpperInvariant() -cne $sourceSha -or $saved.metadata.input_bytes -ne $bytes.Length){throw 'complexity_retained_source_byte_identity'}
   if($saved.metadata.snapshot.state -cne 'completed' -and $null -ne $saved.record.document.payload){throw 'complexity_noncompleted_payload_published'}
   Write-OwnedJson (Join-Path $c.output ($name+'-retained-source-proof.json')) @{status='ACTUAL_READONLY_POSTGRES_RETAINED_SOURCE_IDENTITY';job_id=$job;artifact_id=$artifact;state=$saved.metadata.snapshot.state;source_sha256=$sourceSha;source_bytes=$bytes.Length;raw_record_capture_sha256=Get-OwnedHash $rawPath;http_source_download_not_claimed=$true;payload_present=$null -ne $saved.record.document.payload;report_present=$null -ne $saved.record.document.report}
  }else{
   Write-OwnedJson (Join-Path $c.output ($name+'-retained-source-proof.json')) @{status='NOT_AVAILABLE_AFTER_ACTUAL_HTTP_REFUSAL_OR_MISSING_IDS';ids_not_guessed=$true;http_result_sha256=Get-OwnedHash $resultPath;no_retained_source_identity_claim=$true}
  }
  $allResults.Add(@{case_id=$case.id;events=$case.events;http_result_sha256=Get-OwnedHash $resultPath;retained_source_proof_sha256=Get-OwnedHash (Join-Path $c.output ($name+'-retained-source-proof.json'));pid=$script:app.Record.pid;native_creation_utc=$script:app.Record.native_creation_utc;independent_fresh_process=$true;observations=1})
  StopApp $activeLane ($name+'-only-process')
 }
 Assert-OwnedHash $manifestPath $c.input_manifest_sha
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $success=$true
}catch{
 $primary=$_;try{Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{exception_type=$primary.Exception.GetType().FullName;message=$primary.Exception.Message;position=$primary.InvocationInfo.PositionMessage;script_stack_trace=$primary.ScriptStackTrace;completed_case_receipts=$allResults.ToArray();no_case_retuned_or_repeated=$true}}catch{Write-Warning ('complexity_failure_receipt_diagnostic: '+$_.Exception.Message)};throw $primary
}finally{
 try{
  if($script:app -and !$script:appClosed){StopApp $activeLane 'complexity-fixture-cleanup'}
  if($script:pg -and !$script:pgClosed){
   if(!$script:pg.Process.HasExited){Identity $script:pg $c.postgres $true;[void](Invoke-OwnedPhaseCommand $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') $c.workspace $c.output 'pg-stop' @{} 20 2MB)}
   if(!$script:pg.Process.WaitForExit(10000)){throw 'complexity_pg_stop_timeout'}
   $pgRecord=Complete-Checked $script:pg $true;$script:pgClosed=$true
   if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'complexity_pidfile_not_removed_by_postgres'}
  }
 }catch{
  $cleanup=$_;try{if($script:appJob){$script:appJob.Stop()};$pgJob.Stop()}catch{Write-Warning ('complexity_owned_fallback_diagnostic: '+$_.Exception.Message)}
  foreach($child in @($script:app,$script:pg)){try{if($child -and $child.Process -and $child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning ('complexity_capture_cleanup_diagnostic: '+$_.Exception.Message)}}
  throw $cleanup
 }finally{if($script:appJob){$script:appJob.Dispose()};$pgJob.Dispose()}
}
if($success){Write-OwnedJson (Join-Path $c.output 'complexity-measure-proof.json') @{status='ACTUAL_TWO_FIXED_EVENT_COUNT_OBSERVATIONS';app_sha256=$c.app_sha;input_manifest_sha256=$c.input_manifest_sha;measurement_source_sha256=Get-OwnedHash $PSCommandPath;config_sha256=$PhaseConfigSha;cases=$allResults.ToArray();cases_retuned_or_repeated=$false;native_app_processes=2;native_poll_interval_ms_intended=50;native_peaks_are_each_process_lifetime=$true;postgres_native_exit=$pgRecord.native_exit;all_native_streams_eof=$true;servers_left_running=$false;no_ram_hard_cap_slo_worstcase_diversity_order_sensitivity_or_browser_claim=$true}}
