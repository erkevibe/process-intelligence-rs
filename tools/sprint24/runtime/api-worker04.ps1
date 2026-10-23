param([Parameter(Mandatory)][string]$Ipc,[Parameter(Mandatory)][string]$TaskConfig,[Parameter(Mandatory)][string]$TaskConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $TaskConfig).Hash -cne $TaskConfigSha){throw 'worker_config_pin'}
$c=Get-Content -LiteralPath $TaskConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$sequence=0
function ReadJson([string]$Path,[long]$Cap=2MB){$f=[IO.File]::Open($Path,'Open','Read','ReadWrite');try{if($f.Length -gt $Cap){throw 'json_bound'};$r=[IO.StreamReader]::new($f,[Text.UTF8Encoding]::new($false,$true));$raw=$r.ReadToEnd()}finally{$f.Dispose()};return ($raw|ConvertFrom-Json -AsHashtable -DateKind String)}
function Save([string]$Name,[object]$Value){$b=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 20));if($b.Length -gt 2MB){throw 'worker_proof_bound'};$f=[IO.File]::Open((Join-Path $c.output $Name),'CreateNew','Write','Read');try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()}}
function Request([string]$Line){$script:sequence++;if($script:sequence -gt 512){throw 'worker_request_limit'};$base=Join-Path $Ipc ('{0:D6}' -f $script:sequence);$b=[Text.Encoding]::ASCII.GetBytes($Line+"`n");$f=[IO.File]::Open(($base+'.reqdata'),'CreateNew','Write','Read');try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()};$f=[IO.File]::Open(($base+'.req'),'CreateNew','Write','Read');try{$f.WriteByte(1);$f.Flush($true)}finally{$f.Dispose()};$end=[DateTimeOffset]::UtcNow.AddSeconds(40);while(!(Test-Path -LiteralPath ($base+'.ack'))){if([DateTimeOffset]::UtcNow -ge $end){throw 'worker_ack_timeout'};Start-Sleep -Milliseconds 20};$r=ReadJson ($base+'.ackdata') 65536;if($r.sequence -ne $script:sequence){throw 'ack_sequence'};return $r}
function WaitCommand([string]$Label,[int[]]$Allowed=@(0)){$r=Request ('STATUS '+$Label);while(!$r.exited){Start-Sleep -Seconds 2;$r=Request ('STATUS '+$Label)};if($r.native_exit -notin $Allowed){throw ('native_nonzero_'+$Label)};# Local immutable-receipt consumer barrier, not a generic protocol change.
 $r=Request ('STATUS '+$Label);$p=ReadJson (Join-Path $c.output ('session/'+$Label+'.process.json')) 65536;if($p.pid -ne $r.pid -or $p.native_creation_filetime -ne $r.creation_filetime -or $p.native_exit -ne $r.native_exit -or !$p.stdout_complete -or !$p.stderr_complete -or $p.source_status -cne 'captured'){throw 'complete_receipt_required'};return $r}
function Run([string]$Label,[int[]]$Allowed=@(0)){[void](Request ('START '+$Label));return (WaitCommand $Label $Allowed)}
try{
 [void](Request 'START postgres');$ready=$false;$end=[DateTimeOffset]::UtcNow.AddSeconds(20)
 for($i=1;$i -le 10;$i++){if([DateTimeOffset]::UtcNow -ge $end){break};$r=Run ('ready-'+('{0:D2}' -f $i)) @(0,1,2);if($r.native_exit -eq 0){$ready=$true;break}};if(!$ready){throw 'postgres_not_ready'}
 [void](Run 'source10k');$identity=ReadJson (Join-Path $c.output 'session/source10k.stdout') 65536
 if([IO.Path]::GetFullPath($identity.data_directory) -cne [IO.Path]::GetFullPath($c.pgdata) -or $identity.port -cne '55449' -or $identity.database -cne 'postgres' -or $identity.user -cne 'pi_s21_admin' -or $identity.in_recovery -ne $false){throw 'cluster_identity'}
 [void](Run 'child') # CREATE DATABASE, never reuse an existing database.
 # Legacy labels are protocol aliases only; actual commands remain recorded.
 function Health([string]$Version='0.8.2'){$h=[Net.Http.HttpClientHandler]::new();$h.UseProxy=$false;$h.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($h);$client.Timeout=[TimeSpan]::FromSeconds(2);$client.MaxResponseContentBufferSize=4096;$end=[DateTimeOffset]::UtcNow.AddSeconds(30);$ready=$false;try{while([DateTimeOffset]::UtcNow -lt $end){$response=$null;try{$response=$client.GetAsync('http://127.0.0.1:3144/health').GetAwaiter().GetResult();if([int]$response.StatusCode -eq 200){$v=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable;if($v.status -cne 'ready' -or $v.version -cne $Version){throw 'app_health_identity'};$ready=$true;break}}catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}finally{if($response){$response.Dispose()}};Start-Sleep -Milliseconds 100};if(!$ready){throw 'app_health_timeout'}}finally{$client.Dispose();$h.Dispose()}}
 foreach($pair in @(@('app10k','http90k','http-pre'),@('app90k','source90k','http-post'))){
  [void](Request ('START '+$pair[0]));Health;[void](Run $pair[1]);$proof=ReadJson (Join-Path $c.output ('session/'+$pair[1]+'.stdout')) 65536
  if($proof.status -cne $c.http_proof_status -or $proof.mode -cne $(if($pair[0] -ceq 'app10k'){'pre'}else{'post'})){throw 'original_readback_proof'}
  [void](Request ('KILL '+$pair[0]));[void](WaitCommand $pair[0] @(137))
 }
 [void](Request 'SAMPLE postgres');[void](Run 'pg-stop');[void](WaitCommand 'postgres')
 Save 'worker-proof.json' @{status='ACTUAL_S24_API_WORKER_REQUIRES_INDEPENDENT_ACCEPTANCE';legacy_aliases_not_app_or_HTTP_claim=$true;compiler_executed=$false;stock_server_process_started=$true}
}catch{Save 'worker-failure.json' @{status='FAILED_PARTIAL_ONLY';type=$_.Exception.GetType().FullName;message=$_.Exception.Message};throw}