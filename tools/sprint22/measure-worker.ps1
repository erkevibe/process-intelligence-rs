param([Parameter(Mandatory)][string]$Ipc,[Parameter(Mandatory)][string]$MeasurementConfig,[Parameter(Mandatory)][string]$MeasurementConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $MeasurementConfig).Hash -cne $MeasurementConfigSha){throw 'worker_config_pin'}
$c=Get-Content -LiteralPath $MeasurementConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Add-Type -Path (Join-Path $PSScriptRoot 'MemoryProbe.cs')
$sequence=0;$activeProbe=$null
function Save([string]$Name,[object]$Value){
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 30))
 if($bytes.Length -gt 4MB){throw 'worker_proof_bound'}
 $f=[IO.File]::Open((Join-Path $c.output $Name),'CreateNew','Write','Read');try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
}
function ReadJson([string]$Path,[long]$Limit=4MB){
 $f=[IO.File]::Open($Path,'Open','Read','ReadWrite');try{if($f.Length -gt $Limit){throw 'worker_read_bound'};$reader=[IO.StreamReader]::new($f,[Text.UTF8Encoding]::new($false,$true));$text=$reader.ReadToEnd()}finally{$f.Dispose()}
 return ($text|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String)
}
function Request([string]$Line){
 $script:sequence++;if($script:sequence -gt 512){throw 'worker_request_limit'}
 $base=Join-Path $Ipc ('{0:D6}' -f $script:sequence)
 $bytes=[Text.Encoding]::ASCII.GetBytes($Line+"`n")
 $f=[IO.File]::Open(($base+'.reqdata'),'CreateNew','Write','Read');try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
 $f=[IO.File]::Open(($base+'.req'),'CreateNew','Write','Read');try{$f.WriteByte(1);$f.Flush($true)}finally{$f.Dispose()}
 $end=[DateTimeOffset]::UtcNow.AddSeconds(40)
 while(!(Test-Path -LiteralPath ($base+'.ack'))){if([DateTimeOffset]::UtcNow -ge $end){throw 'worker_ack_timeout'};Start-Sleep -Milliseconds 20}
 $r=ReadJson ($base+'.ackdata') 65536
 if($r.sequence -ne $script:sequence){throw 'worker_ack_sequence'}
 return $r
}
function WaitCommand([string]$Label,[int[]]$Allowed=@(0)){
 $r=Request ('STATUS '+$Label)
 while(!$r.exited){Start-Sleep -Milliseconds 1000;$r=Request ('STATUS '+$Label)}
 if($r.native_exit -notin $Allowed){throw ('native_command_failed_'+$Label)}
 return $r
}
function RunCommand([string]$Label,[int[]]$Allowed=@(0)){[void](Request ('START '+$Label));return (WaitCommand $Label $Allowed)}
function EqualJson([object]$Left,[object]$Right){
 if($null -eq $Left -or $null -eq $Right){return ($null -eq $Left -and $null -eq $Right)}
 if($Left -is [Collections.IDictionary]){
  if($Right -isnot [Collections.IDictionary] -or $Left.Count -ne $Right.Count){return $false}
  foreach($key in $Left.Keys){if($key -cnotin @($Right.Keys) -or !(EqualJson $Left[$key] $Right[$key])){return $false}};return $true
 }
 if($Left -is [array]){if($Right -isnot [array] -or $Left.Count -ne $Right.Count){return $false};for($i=0;$i -lt $Left.Count;$i++){if(!(EqualJson $Left[$i] $Right[$i])){return $false}};return $true}
 return ($Left.GetType() -eq $Right.GetType() -and $Left -ceq $Right)
}
function WaitHealth {
 $handler=[Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false
 $http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[TimeSpan]::FromSeconds(2);$http.MaxResponseContentBufferSize=4096
 $end=[DateTimeOffset]::UtcNow.AddSeconds(30);$ready=$false
 try{while([DateTimeOffset]::UtcNow -lt $end){
  $response=$null
  try{$response=$http.GetAsync('http://127.0.0.1:3139/health').GetAwaiter().GetResult();if([int]$response.StatusCode -eq 200){$b=$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();if($b.Length -gt 4096){throw 'health_byte_bound'};$health=[Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json -AsHashtable;if($health.status -cne 'ready' -or $health.version -cne '0.8.1'){throw 'health_binary_version'};$ready=$true;break}}
  catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}
  finally{if($response){$response.Dispose()}}
  Start-Sleep -Milliseconds 100
 };if(!$ready){throw 'health_deadline'}}finally{$http.Dispose();$handler.Dispose()}
}
$rows=[Collections.Generic.List[object]]::new()
try{
 [void](Request 'START postgres')
 $ready=$false;$readyEnd=[DateTimeOffset]::UtcNow.AddSeconds(20)
 for($i=1;$i -le 12;$i++){if([DateTimeOffset]::UtcNow -ge $readyEnd){break};$r=RunCommand ('ready-'+('{0:D2}' -f $i)) @(0,1,2);if($r.native_exit -eq 0){$ready=$true;break};Start-Sleep -Milliseconds 100}
 if(!$ready){throw 'postgres_ready_bound'}
 [void](RunCommand 'cluster-identity')
 $identity=ReadJson (Join-Path $c.session_output 'cluster-identity.stdout') 65536
 if([IO.Path]::GetFullPath($identity.data_directory) -cne [IO.Path]::GetFullPath($c.pgdata) -or $identity.port -cne '55449' -or $identity.database -cne 'postgres' -or $identity.user -cne 'pi_s21_admin' -or $identity.in_recovery -ne $false){throw 'owned_postgres_cluster_identity_required_before_create'}
 $pgStatus=Request 'STATUS postgres';if($pgStatus.exited){throw 'owned_postgres_not_alive_before_create'}
 [void](RunCommand 'create-db')
 $manifest=ReadJson (Join-Path $c.input_directory 'manifest.json') 65536
 foreach($case in $manifest.cases){
  $small=$case.id -ceq 'CMP10K';$tag=if($small){'10k'}else{'90k'};$appLabel='app'+$tag;$httpLabel=if($small){'child'}else{'http90k'}
  $start=Request ('START '+$appLabel)
  $samples=Join-Path $c.output ('memory-'+$tag+'.ndjson')
  $activeProbe=[S22MemoryProbe]::new([uint32]$start.pid,[long]$start.creation_filetime,$c.app,$samples)
  WaitHealth
  $activeProbe.SetStage('warm_before');Start-Sleep -Seconds 1
  $activeProbe.SetStage('http_client');[void](RunCommand $httpLabel)
  $activeProbe.SetStage('warm_after');Start-Sleep -Seconds 1
  $activeProbe.Dispose()
  if($activeProbe.Fault -or !$activeProbe.Completed -or $activeProbe.Count -lt 1){throw 'memory_complete_coverage_required'}
  Save ('memory-'+$tag+'-proof.json') @{pid=$start.pid;native_creation_filetime=$start.creation_filetime;file=('memory-'+$tag+'.ndjson');sha256=(Get-FileHash -LiteralPath $samples).Hash;bytes=(Get-Item -LiteralPath $samples).Length;samples=$activeProbe.Count;complete_footer_expected=$true;worker_death_would_make_coverage_partial=$true;scope='Read-only retained handle independently matched100ns creation/image against broker; server only, no PG/client; native peaks since creation through final alive snapshot before SQL/teardown; sampled maxima are separate.'}
  $activeProbe=$null
  $result=ReadJson (Join-Path $c.output ('http-'+$tag+'/result.json'))
  if($result.status -cne 'OBSERVATION_COMPLETED' -or $result.submitted_conversions -ne 1 -or $result.events_expected -ne $case.events){throw 'actual_http_terminal_observation_required'}
  $converted=$result.outcome.state -ceq 'completed'
  if(!$converted -and ($result.outcome.state -cne 'failed' -or $result.outcome.error.code -cne 'report_byte_limit' -or $result.downloads.payload.available -or $result.downloads.report.available)){throw 'terminal_outcome_not_declared'}
  if($converted -and (!$result.manual_core_verification.fixed_values_match -or $result.manual_core_verification.rows -ne $case.events -or !$result.downloads.payload.available -or !$result.downloads.report.available)){throw 'converted_manual_pair_required'}
  [void](RunCommand ('source'+$tag))
  $saved=ReadJson (Join-Path $c.session_output ('source'+$tag+'.stdout')) 32MB
  if(@($saved.rows).Count -ne 1){throw 'one_retained_source_record_required'}
  $record=$saved.rows[0]
  $project=@($saved.projects|Where-Object{$_.project_id -ceq $result.project_id})
  if($project.Count -ne 1 -or $record.project_id -cne $result.project_id -or $record.resource_id -cne $result.artifact_id -or !$project[0].conversions.ContainsKey($result.job_id)){throw 'actual_retained_record_identity'}
  $meta=$project[0].conversions[$result.job_id]
  if(!(EqualJson $meta $result.metadata)){throw 'full_postgres_http_metadata_mismatch'}
  $input=[Text.UTF8Encoding]::new($false).GetBytes([string]$record.document.input)
  $sourceSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($input))
  if($sourceSha -cne $case.input_sha256 -or $input.Length -ne $case.input_bytes -or $meta.source_sha256.ToUpperInvariant() -cne $sourceSha -or $meta.snapshot.state -cne $result.outcome.state){throw 'retained_source_bytes_or_terminal_mismatch'}
  if($converted){
   foreach($part in @('payload','report')){$bytes=[Text.UTF8Encoding]::new($false).GetBytes([string]$record.document[$part]);$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes));if($hash -cne $result.downloads[$part].sha256){throw 'postgres_http_pair_bytes_mismatch'}}
  }elseif($null -ne $record.document.payload -or $null -ne $record.document.report -or $null -ne $meta.snapshot.result_id -or $meta.snapshot.error.code -cne 'report_byte_limit'){throw 'refusal_published_pair_or_wrong_error'}
  Save ('source-'+$tag+'-proof.json') @{case_id=$case.id;source_sha256=$sourceSha;source_bytes=$input.Length;project_id=$result.project_id;job_id=$result.job_id;artifact_id=$result.artifact_id;state=$result.outcome.state;postgres_http_pair_or_refusal_verified=$true;raw_sql_sha256=(Get-FileHash (Join-Path $c.session_output ('source'+$tag+'.stdout'))).Hash}
  [void](Request ('KILL '+$appLabel));[void](WaitCommand $appLabel @(137))
  $rows.Add(@{case_id=$case.id;events=$case.events;outcome=$result.outcome.state;error_code=$(if($converted){$null}else{'report_byte_limit'});app_pid=$start.pid;native_creation_filetime=$start.creation_filetime;one_operation=$true;one_fresh_app=$true;http_result_sha256=(Get-FileHash (Join-Path $c.output ('http-'+$tag+'/result.json'))).Hash})
 }
 [void](Request 'SAMPLE postgres')
 [void](RunCommand 'pg-stop')
 [void](WaitCommand 'postgres')
 Save 'worker-measurement-proof.json' @{status='TWO_FIXED_TERMINAL_OBSERVATIONS_AND_COMPLETE_MEMORY_SOURCES';cases=$rows.ToArray();observations_per_case=1;retuned_or_repeated=$false;http_wall_is_not_cpu=$true;browser_checked=$false;utc=[DateTimeOffset]::UtcNow.ToString('o')}
}catch{Save 'worker-measurement-failure.json' @{type=$_.Exception.GetType().FullName;message=$_.Exception.Message;completed_cases=$rows.ToArray();retuned_or_repeated=$false};throw}
finally{if($activeProbe){$activeProbe.Dispose()}}
