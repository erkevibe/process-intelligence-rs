param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# Fixed finite byte-volume observations; sampled server counters are not RAM limits.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'capacity_measure_config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($module in @('owned-runtime.psm1','owned-phase-support.psm1','process-identity.psm1')){Import-Module (Join-Path $c.workspace ('tools/sprint21/'+$module)) -Force -DisableNameChecking}
Import-Module (Join-Path $c.workspace 'tools/sprint20/measured-runtime.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$root=Join-Path $c.workspace '.local/sprint21/root'
if($c.pgdata -cne (Join-Path $root 'pgdata11') -or $c.pg_port -ne 55449 -or $c.app_port -ne 3137 -or (Split-Path -Parent $c.input_directory) -cne $root -or (Split-Path -Leaf $c.input_directory) -cnotmatch '^capacity-inputs[0-9]{2}$'){throw 'capacity_measure_exact_scope'}
if($c.prepare_inputs -cne (Join-Path $c.workspace 'tools/sprint21-capacity/prepare-inputs.py') -or $c.http_helper -cne (Join-Path $c.workspace 'tools/sprint21-capacity/capacity-http.py')){throw 'capacity_measure_helper_scope'}
Assert-OwnedHash $c.prepare_inputs $c.prepare_inputs_sha;Assert-OwnedHash $c.http_helper $c.http_helper_sha
Assert-OwnedPrivateDirectory $c.output;Assert-OwnedPrivateDirectory $c.pgdata
if([IntPtr]::Size -ne 8 -or ([PiS20MeasuredJob]::StructureSizes() -join ',') -cne '64,144,48,80'){throw 'capacity_measure_memory_abi'}
Write-OwnedJson (Join-Path $c.output 'memory-abi.json') @{pointer_bytes=[IntPtr]::Size;structure_sizes=[PiS20MeasuredJob]::StructureSizes();sampling_scope='actual owned server process handle'}
if(Test-Path -LiteralPath $c.input_directory){throw 'capacity_measure_input_output_must_be_fresh'}
if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'capacity_measure_cluster_not_stopped'}
if([IO.File]::ReadAllText((Join-Path $c.pgdata 'PG_VERSION')).Trim() -cne '18'){throw 'capacity_measure_cluster_version'}
if(@($c.lanes).Count -ne 2 -or $c.lanes[0].name -cne 'baseline' -or $c.lanes[0].database -cne 'pi_s21_capacity_b' -or $c.lanes[1].name -cne 'candidate' -or $c.lanes[1].database -cne 'pi_s21_capacity_c'){throw 'capacity_measure_fixed_lanes'}
foreach($lane in $c.lanes){Assert-OwnedHash $lane.app $lane.app_sha;if([string]$lane.expected_version -notmatch '^0\.[0-9]+\.[0-9]+$'){throw 'capacity_measure_expected_version'}}
foreach($port in @([int]$c.pg_port,[int]$c.app_port)){$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$probe.Start()}finally{$probe.Stop()}}
$started=[DateTimeOffset]::UtcNow;$freeze=[DateTimeOffset]$c.phase_deadline_utc
$until=$started.AddMinutes(25);if($until -gt $freeze){$until=$freeze}
$script:pg=$null;$script:pgClosed=$false;$script:app=$null;$script:appClosed=$true;$script:appJob=$null;$script:appUntil=$until
$pgJob=[PiOwnedJob]::new();$success=$false;$allResults=[Collections.Generic.List[object]]::new();$script:activeNative=$null
function Bounds {
 if([DateTimeOffset]::UtcNow -ge $until -or [DateTimeOffset]::UtcNow -ge $freeze -or (Get-PSDrive C).Free -lt 8GB){throw 'capacity_measure_time_or_free_floor'}
 if($script:pg -and !$script:pgClosed){if($script:pg.Process.HasExited -or $script:pg.OutCapture.LimitReached -or $script:pg.ErrCapture.LimitReached -or $script:pg.OutCapture.Pump.IsFaulted -or $script:pg.ErrCapture.Pump.IsFaulted){throw 'capacity_measure_pg_exit_or_capture'}}
 if($script:app -and !$script:appClosed){if([DateTimeOffset]::UtcNow -ge $script:appUntil -or $script:app.Process.HasExited -or $script:app.OutCapture.LimitReached -or $script:app.ErrCapture.LimitReached -or $script:app.OutCapture.Pump.IsFaulted -or $script:app.ErrCapture.Pump.IsFaulted){throw 'capacity_measure_app_exit_time_or_capture'}}
}
function Identity($Child,[string]$Program,[bool]$Pg=$false){
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Child.Process.Id)
 Assert-S21ProcessIdentity $Child $Program $row
 if($Pg){[void](Get-OwnedDatadirArgument ([string]$row.CommandLine) $c.pgdata)}
}
function Complete-Checked($Child,[bool]$Zero){
 $r=Complete-OwnedCapturedProcess $Child
 if(($Zero -and $r.native_exit -ne 0) -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'capacity_measure_native_exit_or_full_capture'}
 return $r
}
function Sample([string]$Stage,[DateTimeOffset]$PhaseStart){
 Bounds
 if(!$script:app -or $script:appClosed){throw 'capacity_measure_sample_without_live_owned_app'}
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
  $script:activeNative=$native;$commandJob.Assign($native.Handle);if(!$commandJob.Member($native.Handle)){throw 'capacity_measure_native_job'}
  $end=[DateTimeOffset]::UtcNow.AddSeconds($Seconds);$next=[DateTimeOffset]::UtcNow
  while(!$native.Process.WaitForExit(10)){
   Bounds
   if([DateTimeOffset]::UtcNow -ge $end){$fault='native_timeout'}
   if($native.OutCapture.LimitReached -or $native.ErrCapture.LimitReached -or $native.OutCapture.Pump.IsFaulted -or $native.ErrCapture.Pump.IsFaulted){$fault='native_capture_fault'}
   if($fault){throw $fault}
   if($Measure -and [DateTimeOffset]::UtcNow -ge $next){$samples.Add((Sample 'during_http_child' $phaseStart));if($samples.Count -gt 6000){throw 'capacity_measure_sample_count'};$next=[DateTimeOffset]::UtcNow.AddMilliseconds(50)}
  }
  if($Measure){$samples.Add((Sample 'http_child_exited' $phaseStart))}
  $r=Complete-Checked $native $false;$closed=$true;$script:activeNative=$null
  if($r.native_exit -notin $AllowedExits){throw 'capacity_measure_unexpected_native_exit'}
  if($Measure){IdleSamples $samples 'after_http' $phaseStart}
  return $r
 }finally{
  try{
   if($native -and !$closed){if(!$native.Process.HasExited){$commandJob.Stop()};if($native.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $native);$closed=$true}else{throw 'capacity_measure_owned_child_stop_timeout'}}
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
  Bounds;if([DateTimeOffset]::UtcNow -ge $readyEnd){throw 'capacity_measure_pg_ready_deadline'}
  $r=Native $c.pg_isready $c.pg_isready_sha @('-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_s21_admin','-d','postgres','-t','1') ('pg-readiness-'+('{0:D2}' -f $attempt)) @{} 3 $false @(0,1,2) 64KB
  if($r.native_exit -eq 0){return};Start-Sleep -Milliseconds 200
 }
 throw 'capacity_measure_pg_ready_attempt_limit'
}
function StartApp($Lane,[string]$Suffix){
 Bounds
 if(!$script:appClosed){throw 'capacity_measure_app_already_live'}
 Identity $script:pg $c.postgres $true
 $script:appJob=[PiOwnedJob]::new()
 $script:app=Start-OwnedCapturedProcess -Program $Lane.app -ProgramSha256 $Lane.app_sha -Arguments @() -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label ($Lane.name+'-app-'+$Suffix) -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL="host=127.0.0.1 port=$($c.pg_port) user=pi_s21_app dbname=$($Lane.database) connect_timeout=5 application_name=s21_capacity_measure";PORT='3137';RUST_LOG='info'}
 $script:appClosed=$false;$script:appUntil=[DateTimeOffset]::UtcNow.AddMinutes(15);$script:appJob.Assign($script:app.Handle)
 if(!$script:appJob.Member($script:app.Handle)){throw 'capacity_measure_app_job'}
 $http=[Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{UseProxy=$false;AllowAutoRedirect=$false});$http.Timeout=[TimeSpan]::FromSeconds(2)
 try{
  $ready=$false;$healthEnd=[DateTimeOffset]::UtcNow.AddSeconds(30)
  while([DateTimeOffset]::UtcNow -lt $healthEnd){
   Bounds;$response=$null
   try{$response=$http.GetAsync('http://127.0.0.1:3137/health').GetAwaiter().GetResult();if([int]$response.StatusCode -eq 200){$body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if($body.Length -gt 4096){throw 'capacity_measure_health_cap'};$health=$body|ConvertFrom-Json -AsHashtable;if($health.status -cne 'ready' -or $health.version -cne $Lane.expected_version){throw 'capacity_measure_actual_binary_version'};$ready=$true;break}}catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}finally{if($response){$response.Dispose()}}
   Start-Sleep -Milliseconds 100
  }
  if(!$ready){throw 'capacity_measure_app_health_timeout'}
 }finally{$http.Dispose()}
 Identity $script:app $Lane.app
 Write-OwnedJson (Join-Path $c.output ($Lane.name+'-app-'+$Suffix+'-ready.json')) @{lane=$Lane.name;expected_version=$Lane.expected_version;actual_health=$health;pid=$script:app.Record.pid;native_creation_utc=$script:app.Record.native_creation_utc;app_sha256=$Lane.app_sha;native_lifetime_counters=Get-S20MeasuredProcessMemory $script:app.Handle}
}
function StopApp($Lane,[string]$Label){
 if(!$script:app -or $script:appClosed){return}
 $terminalMemory=$null
 if(!$script:app.Process.HasExited){Identity $script:app $Lane.app;$terminalMemory=Get-S20MeasuredProcessMemory $script:app.Handle;$script:appJob.Stop()}
 if(!$script:app.Process.WaitForExit(10000)){throw 'capacity_measure_app_stop_timeout'}
 $r=Complete-Checked $script:app $false;$script:appClosed=$true;$script:appJob.Dispose();$script:appJob=$null
 Write-OwnedJson (Join-Path $c.output ($Label+'-stop.json')) @{controlled_forced_stop=$true;clean_shutdown_not_claimed=$true;native_exit=$r.native_exit;pid=$r.pid;native_creation_utc=$r.native_creation_utc;full_streams_eof=$true;last_pre_stop_lifetime_counters=$terminalMemory;lifetime_counter_scope='Since process creation through this last pre-stop observation; excludes later teardown.'}
}
$activeLane=$null
try{
 # Generator runs once, before either server app is launched or measured.
 [void](Native $c.python $c.python_sha @($c.prepare_inputs,'--workspace',$c.workspace,'--output',$c.input_directory) 'prepare-fixed-inputs' @{PYTHONDONTWRITEBYTECODE='1'} 30)
 $manifest=Join-Path $c.input_directory 'manifest.json'
 $manifestSha=Get-OwnedHash $manifest
 Write-OwnedJson (Join-Path $c.output 'prospective-inputs-before-measurements.json') @{input_manifest_sha256=$manifestSha;generated_once_before_apps=$true;utc=[DateTimeOffset]::UtcNow.ToString('o');measurement_or_converter_result_not_used_for_selection=$true}
 $script:pg=Start-OwnedCapturedProcess -Program $c.postgres -ProgramSha256 $c.postgres_sha -Arguments @('-D',$c.pgdata,'-h','127.0.0.1','-p',[string]$c.pg_port,'-c','max_connections=24','-c','shared_buffers=32MB','-c','max_wal_size=128MB','-c','min_wal_size=32MB','-c','logging_collector=off','-c','log_statement=none') -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label 'postgres' -MaxOutputBytes 8MB
 $pgJob.Assign($script:pg.Handle);if(!$pgJob.Member($script:pg.Handle)){throw 'capacity_measure_pg_job'}
 WaitPg;Identity $script:pg $c.postgres $true
 [void](Sql 'sql-owned-cluster' "SELECT json_build_object('data_directory',current_setting('data_directory'),'database',current_database(),'user',current_user,'in_recovery',pg_is_in_recovery(),'port',inet_server_port())")
 $cluster=Get-Content -LiteralPath (Join-Path $c.output 'sql-owned-cluster.stdout') -Raw|ConvertFrom-Json -AsHashtable
 if($cluster.database -cne 'postgres' -or $cluster.user -cne 'pi_s21_admin' -or $cluster.in_recovery -ne $false -or $cluster.port -ne 55449 -or !([IO.Path]::GetFullPath([string]$cluster.data_directory)).Equals([IO.Path]::GetFullPath([string]$c.pgdata),[StringComparison]::OrdinalIgnoreCase)){throw 'capacity_measure_actual_cluster_identity'}
 foreach($lane in $c.lanes){[void](Sql ('create-'+$lane.name+'-database') ('CREATE DATABASE '+$lane.database+' OWNER pi_s21_app'))}
 foreach($lane in $c.lanes){
  $activeLane=$lane
  StartApp $lane 'initial'
  $credentials=Join-Path $c.output ($lane.name+'-private-credentials.json')
  foreach($case in @('setup','control','padded','overlap')){
   Bounds;Assert-OwnedHash $manifest $manifestSha
   $caseOutput=Join-Path $c.output ($lane.name+'-'+$case+'-http')
   $label=$lane.name+'-'+$case
   [void](Native $c.python $c.python_sha @($c.http_helper,'--url','http://127.0.0.1:3137','--inputs',$c.input_directory,'--output',$caseOutput,'--credentials',$credentials,'--case',$case) $label @{PYTHONDONTWRITEBYTECODE='1'} 120 $true)
   $resultPath=Join-Path $caseOutput 'result.json'
   if(!(Test-Path -LiteralPath $resultPath) -or (Get-Item -LiteralPath $resultPath).Length -gt 4MB){throw 'capacity_measure_http_result_missing_or_oversized'}
   $allResults.Add(@{lane=$lane.name;case=$case;result_sha256=Get-OwnedHash $resultPath;native_app_pid=$script:app.Record.pid;native_app_creation_utc=$script:app.Record.native_creation_utc})
  }
  if($lane.name -ceq 'candidate'){
   if($c.tcp_helper -cne (Join-Path $c.workspace 'tools/sprint21-capacity/tcp-boundaries.py')){throw 'capacity_tcp_helper_scope'}
   Assert-OwnedHash $c.tcp_helper $c.tcp_helper_sha
   $tcpOutput=Join-Path $c.output 'candidate-tcp-boundaries-http'
   [void](Native $c.python $c.python_sha @('-I','-B',$c.tcp_helper,'--url','http://127.0.0.1:3137','--inputs',$c.input_directory,'--output',$tcpOutput,'--credentials',$credentials) 'candidate-tcp-boundaries' @{PYTHONDONTWRITEBYTECODE='1'} 120 $true)
   $allResults.Add(@{lane=$lane.name;case='tcp-boundaries';result_sha256=Get-OwnedHash (Join-Path $tcpOutput 'result.json');native_app_pid=$script:app.Record.pid;native_app_creation_utc=$script:app.Record.native_creation_utc})
  }
  StopApp $lane ($lane.name+'-before-restart')
  StartApp $lane 'restarted'
  $caseOutput=Join-Path $c.output ($lane.name+'-restart-check-http')
  [void](Native $c.python $c.python_sha @($c.http_helper,'--url','http://127.0.0.1:3137','--inputs',$c.input_directory,'--output',$caseOutput,'--credentials',$credentials,'--case','restart-check') ($lane.name+'-restart-check') @{PYTHONDONTWRITEBYTECODE='1'} 120 $true)
  $allResults.Add(@{lane=$lane.name;case='restart-check';result_sha256=Get-OwnedHash (Join-Path $caseOutput 'result.json');native_app_pid=$script:app.Record.pid;native_app_creation_utc=$script:app.Record.native_creation_utc})
  StopApp $lane ($lane.name+'-after-restart-check')
 }
 Assert-OwnedHash $manifest $manifestSha
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 $success=$true
}catch{
 $mainFailure=$_
 try{Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{exception_type=$mainFailure.Exception.GetType().FullName;message=$mainFailure.Exception.Message;position=$mainFailure.InvocationInfo.PositionMessage;script_stack_trace=$mainFailure.ScriptStackTrace;utc=[DateTimeOffset]::UtcNow.ToString('o');completed_result_receipts=$allResults.ToArray()}}catch{Write-Warning ('capacity_measure_failure_receipt_diagnostic: '+$_.Exception.Message)}
 throw $mainFailure
}finally{
 try{
  if($script:app -and !$script:appClosed){StopApp $activeLane 'fixture-cleanup'}
  if($script:pg -and !$script:pgClosed){
   if(!$script:pg.Process.HasExited){Identity $script:pg $c.postgres $true;[void](Invoke-OwnedPhaseCommand $c.pg_ctl $c.pg_ctl_sha @('-D',$c.pgdata,'-w','-t','15','-m','fast','stop') $c.workspace $c.output 'pg-stop' @{} 20 2MB)}
   if(!$script:pg.Process.WaitForExit(10000)){throw 'capacity_measure_pg_stop_timeout'}
   $pgRecord=Complete-Checked $script:pg $true;$script:pgClosed=$true
   if(Test-Path -LiteralPath (Join-Path $c.pgdata 'postmaster.pid')){throw 'capacity_measure_pidfile_not_removed_by_postgres'}
  }
 }catch{
  $cleanupError=$_
  try{if($script:appJob){$script:appJob.Stop()};$pgJob.Stop()}catch{Write-Warning ('capacity_measure_owned_fallback_diagnostic: '+$_.Exception.Message)}
  foreach($child in @($script:app,$script:pg)){try{if($child -and $child.Process -and $child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}catch{Write-Warning ('capacity_measure_capture_cleanup_diagnostic: '+$_.Exception.Message)}}
  throw $cleanupError
 }finally{if($script:appJob){$script:appJob.Dispose()};$pgJob.Dispose()}
}
if($success){
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 Write-OwnedJson (Join-Path $c.output 'measured-http-proof.json') @{status='ACTUAL_FINITE_BASELINE_CANDIDATE_HTTP_AND_SAMPLED_PROCESS_MEMORY';config_sha256=$PhaseConfigSha;fixed_input_manifest_sha256=$manifestSha;results=$allResults.ToArray();postgres_native_exit=$pgRecord.native_exit;all_native_streams_eof=$true;servers_left_running=$false;intended_sample_interval_ms=50;native_peaks_are_server_lifetime_not_per_operation=$true;working_set_is_distinct_from_private_commit=$true;byte_volume_two_event_workload_only=$true;ram_hard_cap_slo_throughput_browser_acceptance_not_claimed=$true}
}
