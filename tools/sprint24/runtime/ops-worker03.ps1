param([Parameter(Mandatory)][string]$Ipc,[Parameter(Mandatory)][string]$TaskConfig,[Parameter(Mandatory)][string]$TaskConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $TaskConfig).Hash -cne $TaskConfigSha){throw 'worker_config_pin'}
$c=Get-Content -LiteralPath $TaskConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$sequence=0
function ReadJson([string]$Path,[long]$Cap=2MB){$f=[IO.File]::Open($Path,'Open','Read','ReadWrite');try{if($f.Length -gt $Cap){throw 'json_bound'};$r=[IO.StreamReader]::new($f,[Text.UTF8Encoding]::new($false,$true));$raw=$r.ReadToEnd()}finally{$f.Dispose()};return ($raw|ConvertFrom-Json -AsHashtable -DateKind String)}
function Save([string]$Name,[object]$Value){$b=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 20));if($b.Length -gt 2MB){throw 'worker_proof_bound'};$f=[IO.File]::Open((Join-Path $c.output $Name),'CreateNew','Write','Read');try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()}}
function Request([string]$Line,[int]$AckSeconds=40){if($AckSeconds -lt 1 -or $AckSeconds -gt 100){throw 'ack_deadline_bound'};$script:sequence++;if($script:sequence -gt 512){throw 'worker_request_limit'};$base=Join-Path $Ipc ('{0:D6}' -f $script:sequence);$b=[Text.Encoding]::ASCII.GetBytes($Line+"`n");$f=[IO.File]::Open(($base+'.reqdata'),'CreateNew','Write','Read');try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()};$f=[IO.File]::Open(($base+'.req'),'CreateNew','Write','Read');try{$f.WriteByte(1);$f.Flush($true)}finally{$f.Dispose()};$end=[DateTimeOffset]::UtcNow.AddSeconds($AckSeconds);while(!(Test-Path -LiteralPath ($base+'.ack'))){if([DateTimeOffset]::UtcNow -ge $end){throw 'worker_ack_timeout'};Start-Sleep -Milliseconds 20};$r=ReadJson ($base+'.ackdata') 65536;if($r.sequence -ne $script:sequence){throw 'ack_sequence'};return $r}
function WaitCommand([string]$Label,[int[]]$Allowed=@(0)){$r=Request ('STATUS '+$Label);while(!$r.exited){Start-Sleep -Seconds 2;$r=Request ('STATUS '+$Label)};if($r.native_exit -notin $Allowed){throw ('native_nonzero_'+$Label)};# Local immutable-receipt consumer barrier, not a generic protocol change.
 $r=Request ('STATUS '+$Label);$p=ReadJson (Join-Path $c.output ('session/'+$Label+'.process.json')) 65536;if($p.pid -ne $r.pid -or $p.native_creation_filetime -ne $r.creation_filetime -or $p.native_exit -ne $r.native_exit -or !$p.stdout_complete -or !$p.stderr_complete -or $p.source_status -cne 'captured'){throw 'complete_receipt_required'};return $r}
function Run([string]$Label,[int[]]$Allowed=@(0)){[void](Request ('START '+$Label));return (WaitCommand $Label $Allowed)}
 function Health([string]$Version='0.8.2'){$h=[Net.Http.HttpClientHandler]::new();$h.UseProxy=$false;$h.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($h);$client.Timeout=[TimeSpan]::FromSeconds(2);$client.MaxResponseContentBufferSize=4096;$end=[DateTimeOffset]::UtcNow.AddSeconds(30);$ready=$false;try{while([DateTimeOffset]::UtcNow -lt $end){$response=$null;try{$response=$client.GetAsync('http://127.0.0.1:3144/health').GetAwaiter().GetResult();if([int]$response.StatusCode -eq 200){$v=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable;if($v.status -cne 'ready' -or $v.version -cne $Version){throw 'app_health_identity'};$ready=$true;break}}catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}finally{if($response){$response.Dispose()}};Start-Sleep -Milliseconds 100};if(!$ready){throw 'app_health_timeout'}}finally{$client.Dispose();$h.Dispose()}}
try{
 function Ready([string]$Generation){$ok=$false;for($i=1;$i -le 5;$i++){$r=Run ('ready-'+$Generation+'-'+('{0:D2}' -f $i)) @(0,1,2);if($r.native_exit -eq 0){$ok=$true;break}};if(!$ok){throw 'pg_generation_not_ready'}}
 function Cluster([string]$Label){[void](Run $Label);$v=ReadJson (Join-Path $c.output ('session/'+$Label+'.stdout')) 65536;if([IO.Path]::GetFullPath($v.data_directory) -cne $c.pgdata -or $v.port -cne '55449' -or $v.database -cne 'postgres' -or $v.user -cne 'pi_s21_admin' -or $v.in_recovery -ne $false){throw 'ops_cluster_identity'}}
 function Check([string]$Mode){[void](Run ('http-'+$Mode));$v=ReadJson (Join-Path $c.output ('session/http-'+$Mode+'.stdout')) 65536;if($v.status -cne 'ACTUAL_S24_OPERATIONS_HTTP_PASS' -or $v.mode -cne $Mode){throw 'ops_checker_summary'}}
 [void](Request 'START postgres-g1');Ready 'g1';Cluster 'cluster-g1';[void](Run 'create-db')
 [void](Request 'START app-live');Health;Check 'seed';[void](Run 'snapshot-before')
 [void](Run 'app-duplicate' @(1));
 $duplicateText='';$duplicatePins=@{}
 foreach($stream in @('stdout','stderr')){
  $path=Join-Path $c.output ('session/app-duplicate.'+$stream);$f=[IO.File]::Open($path,'Open','Read','ReadWrite')
  try{if($f.Length -gt 1048576){throw 'duplicate_capture_bound'};$reader=[IO.StreamReader]::new($f,[Text.UTF8Encoding]::new($false,$true));$duplicateText+=$reader.ReadToEnd()}finally{$f.Dispose()}
  $duplicatePins[$stream]=(Get-FileHash -LiteralPath $path).Hash
 }
 $expected='С этой базой уже работает приложение. Остановите прежний экземпляр.'
 if(!$duplicateText.Contains($expected,[StringComparison]::Ordinal) -or $duplicateText.Contains('"app_started"',[StringComparison]::Ordinal)){throw 'duplicate_not_source_bound_single_writer_refusal'}
 Save 'duplicate-refusal-proof.json' @{status='ACTUAL_LOCALIZED_DUPLICATE_REFUSAL';mapped_source_code='app_already_running';public_message=$expected;capture_sha256=$duplicatePins;internal_code_not_claimed_printed=$true}
[void](Run 'snapshot-lease');Check 'lease-check'
 [void](Request 'PGSTOP postgres-g1' 100);[void](WaitCommand 'postgres-g1');[void](WaitCommand 'pg-stop-g1')
 Check 'down'
 [void](Request 'START postgres-g2');Ready 'g2';Cluster 'cluster-g2';Check 'latched'
 [void](Request 'KILL app-live');[void](WaitCommand 'app-live' @(137))
 [void](Request 'START app-restarted');Health;Check 'restored';[void](Run 'snapshot-after')
 [void](Request 'KILL app-restarted');[void](WaitCommand 'app-restarted' @(137))
 [void](Request 'PGSTOP postgres-g2' 100);[void](WaitCommand 'postgres-g2');[void](WaitCommand 'pg-stop-g2')
 Save 'worker-proof.json' @{status='ACTUAL_OPS_REQUIRES_INDEPENDENT_ACCEPTANCE';same_live_adapter_across_pg_generations=$true;new_app_required_for_ready=$true}
}catch{Save 'worker-failure.json' @{status='FAILED_PARTIAL_ONLY';type=$_.Exception.GetType().FullName;message=$_.Exception.Message};throw}
