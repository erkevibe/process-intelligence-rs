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

function ReadText([string]$Label,[string]$Side='stdout'){$p=Join-Path $c.output ('session/'+$Label+'.'+$Side);$f=[IO.File]::Open($p,'Open','Read','Read');try{if($f.Length -gt 65536){throw 'raw_text_bound'};$r=[IO.StreamReader]::new($f,[Text.UTF8Encoding]::new($false,$true));return $r.ReadToEnd()}finally{$f.Dispose()}}

function Snapshot([string]$Label,[string]$Name){[void](Run $Label);$path=Join-Path $c.output ('session/'+$Label+'.stdout');$s=[IO.File]::Open($path,'Open','Read','Read');try{if($s.Length -gt 2MB){throw 'snapshot_bound'};$bytes=[byte[]]::new([int]$s.Length);$s.ReadExactly($bytes)}finally{$s.Dispose()};if($bytes.Length -gt 2MB){throw 'snapshot_bound'};$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);$lines=@($text.TrimEnd([char[]]@([char]13,[char]10)).Split([char]10));if($lines.Count -ne 2 -or $lines[1].TrimEnd([char]13) -cne 'DR24_SNAPSHOT_COMMITTED_V1'){throw 'snapshot_marker'};$raw=[Text.UTF8Encoding]::new($false).GetBytes($lines[0].TrimEnd([char]13));$dest=[IO.File]::Open((Join-Path $c.output $Name),'CreateNew','Write','Read');try{$dest.Write($raw,0,$raw.Length);$dest.Flush($true)}finally{$dest.Dispose()}}
function Cohort([string]$Label,[string]$Name){[void](Run $Label);$lines=@((ReadText $Label).Trim().Split([char]10));if($lines.Count -ne 2 -or $lines[1].Trim() -cne 'DR24_COHORT_COMMITTED_V1'){throw 'cohort_marker'};$v=$lines[0]|ConvertFrom-Json -AsHashtable -DateKind String;if($v.other_sessions -ne 0 -or $v.physical_bytes -gt 128MB -or $v.auth_users -ne 1 -or $v.auth_projects -ne 2 -or !$v.sole_owners){throw 'cohort_contract'};$bytes=[Text.UTF8Encoding]::new($false).GetBytes($lines[0].TrimEnd([char]13));$f=[IO.File]::Open((Join-Path $c.output $Name),'CreateNew','Write','Read');try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}}
 function Health([string]$Version='0.8.2'){$h=[Net.Http.HttpClientHandler]::new();$h.UseProxy=$false;$h.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($h);$client.Timeout=[TimeSpan]::FromSeconds(2);$client.MaxResponseContentBufferSize=4096;$end=[DateTimeOffset]::UtcNow.AddSeconds(30);$ready=$false;try{while([DateTimeOffset]::UtcNow -lt $end){$response=$null;try{$response=$client.GetAsync('http://127.0.0.1:3146/health').GetAwaiter().GetResult();if([int]$response.StatusCode -eq 200){$v=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable;if($v.status -cne 'ready' -or $v.version -cne $Version){throw 'app_health_identity'};$ready=$true;break}}catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}finally{if($response){$response.Dispose()}};Start-Sleep -Milliseconds 100};if(!$ready){throw 'app_health_timeout'}}finally{$client.Dispose();$h.Dispose()}}
try{
 $shaBytes=[Text.Encoding]::ASCII.GetBytes($TaskConfigSha);$shaFile=[IO.File]::Open((Join-Path $c.output 'config.sha256'),'CreateNew','Write','Read');try{$shaFile.Write($shaBytes,0,$shaBytes.Length);$shaFile.Flush($true)}finally{$shaFile.Dispose()}
 [void](Request 'START postgres');$ready=$false
 for($i=1;$i -le 10;$i++){$r=Run ('ready-'+('{0:D2}' -f $i)) @(0,1,2);if($r.native_exit -eq 0){$ready=$true;break}};if(!$ready){throw 'postgres_not_ready'}
 [void](Run 'source10k');$v=ReadJson (Join-Path $c.output 'session/source10k.stdout') 65536
 if([IO.Path]::GetFullPath($v.data_directory) -cne $c.pgdata -or $v.port -cne '55449' -or $v.database -cne 'postgres' -or $v.user -cne 'pi_s21_admin' -or $v.in_recovery -ne $false -or $v.target_exists -ne $false){throw 'cluster_identity_or_target_present'}
 Cohort 'source-cohort' 'cohort-source.json'
 [void](Run 'check-cohort')
 Snapshot 'app10k' 'snapshot-source-before.json'
 [void](Run 'dump-current');$dump=Get-Item -LiteralPath $c.dump;if($dump.Length -le 0 -or $dump.Length -gt 128MB){throw 'dump_bound'}
 $dumpLength=$dump.Length;$dumpSha=(Get-FileHash -LiteralPath $c.dump).Hash
 [void](Run 'list-current')
 Snapshot 'app90k' 'snapshot-source-after-dump.json'
 [void](Run 'create-target');[void](Run 'restore-current')
 if((Get-Item -LiteralPath $c.dump).Length -ne $dumpLength -or (Get-FileHash -LiteralPath $c.dump).Hash -cne $dumpSha){throw 'dump_changed_during_restore'}
 Snapshot 'child' 'snapshot-target-before-app.json'
 [void](Run 'compare-pre')
 [void](Request 'START app-restored');Health
 [void](Run 'http90k');$proof=ReadJson (Join-Path $c.output 'http-restored/proof.json') 65536;if($proof.status -cne 'ACTUAL_CURRENT_COMPACT_DR_HTTP_PASS' -or !$proof.new_owner_login){throw 'restored_http_proof'}
 [void](Request 'KILL app-restored');[void](WaitCommand 'app-restored' @(137))
 Snapshot 'target-after' 'snapshot-target-after-login.json'
 Cohort 'target-cohort' 'cohort-target-after.json'
 Snapshot 'source90k' 'snapshot-source-final.json'
 foreach($label in @('compare-all','audit-current','audit-legacy')){[void](Run $label)}
 [void](Request 'SAMPLE postgres');[void](Run 'pg-stop');[void](WaitCommand 'postgres')
 Save 'dr-worker-proof.json' @{status='ACTUAL_CURRENT_COMPACT_DR_REQUIRES_INDEPENDENT_ACCEPTANCE';source_database_readonly=$true;target_new_login=$true;full_database_backup_not_cluster=$true;input_HTTP_endpoint_not_claimed=$true;compiler_executed=$false;dump_sha256=$dumpSha;dump_bytes=$dumpLength;dump_unchanged_after_restore=$true}
}catch{Save 'worker-failure.json' @{status='FAILED_PARTIAL_ONLY';type=$_.Exception.GetType().FullName;message=$_.Exception.Message};throw}
