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
function Negative([string]$Label,[string]$Code,[string]$Reason=''){[void](Run $Label @(3));$out=ReadText $Label;$err=ReadText $Label 'stderr';if($out.Contains('CAPACITY_DIAGNOSTIC_COMMITTED_V1') -or !$err.Contains($Code) -or ($Reason -and !$err.Contains($Reason))){throw ('negative_oracle_'+$Label)}}
function FreshSerialCapacity{
 $started=[DateTimeOffset]::UtcNow;$until=$started.AddSeconds(80)
 while([DateTimeOffset]::UtcNow -lt $until){
  foreach($f in @(Get-ChildItem -LiteralPath (Join-Path $c.output 'session') -Filter 'capacity-*.json' -File)){
   try{$s=[IO.File]::Open($f.FullName,'Open','Read','ReadWrite');try{if($s.Length -gt 65536){throw 'capacity_receipt_bound'};$reader=[IO.StreamReader]::new($s);$text=$reader.ReadToEnd();if([string]::IsNullOrWhiteSpace($text)){continue};try{$v=$text|ConvertFrom-Json -AsHashtable -DateKind String}catch [ArgumentException]{continue}}finally{$s.Dispose()}}catch [IO.IOException]{if(($_.Exception.HResult -band 65535) -eq 32){continue};throw}
   if([DateTimeOffset]$v.started_utc -ge $started -and [DateTimeOffset]$v.completed_utc -le [DateTimeOffset]::UtcNow -and ([DateTimeOffset]::UtcNow-[DateTimeOffset]$v.completed_utc).TotalSeconds -le 2 -and $v.root_guard_sha256 -ceq $c.guard_sha){return $v}
  };Start-Sleep -Milliseconds 50
 };throw 'serial_capacity_receipt_timeout'
}
try{
 [void](Request 'START postgres');$ready=$false
 for($i=1;$i -le 10;$i++){$r=Run ('ready-'+('{0:D2}' -f $i)) @(0,1,2);if($r.native_exit -eq 0){$ready=$true;break}};if(!$ready){throw 'postgres_not_ready'}
 [void](Run 'source10k');$v=ReadJson (Join-Path $c.output 'session/source10k.stdout') 65536
 if([IO.Path]::GetFullPath($v.data_directory) -cne $c.pgdata -or $v.port -cne '55449' -or $v.database -cne 'postgres' -or $v.user -cne 'pi_s21_admin' -or $v.in_recovery -ne $false){throw 'cluster_identity'}
 foreach($label in @('create-control','create-empty','setup-control')){[void](Run $label)}
 [void](Run 'app10k');$lines=@((ReadText 'app10k').Trim().Split([char]10)|ForEach-Object{$_.Trim()})
 if($lines.Count -ne 2 -or $lines[1] -cne 'CAPACITY_DIAGNOSTIC_COMMITTED_V1'){throw 'positive_completion_marker'}
 $report=$lines[0]|ConvertFrom-Json -AsHashtable -DateKind String
 if(($report.schema_version -isnot [int] -and $report.schema_version -isnot [long]) -or $report.schema_version -ne 1 -or $report.database -cne 'pi_s24_ops02' -or $report.transaction_read_only -cne 'on' -or $report.transaction_isolation -cne 'repeatable read' -or ($report.project_count -isnot [int] -and $report.project_count -isnot [long]) -or $report.project_count -ne 1){throw 'positive_contract'}
 if(($report.database_physical_bytes -isnot [int] -and $report.database_physical_bytes -isnot [long]) -or $report.database_physical_bytes -lt 0){throw 'database_physical_bytes_type'}
 $relations=@('pi_kv','pi_schema_migrations','pi_projects','pi_records','pi_migration_v2');$seenRelations=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 if($report.managed_relations.Count -ne 5){throw 'managed_relation_count'}
 foreach($relation in $report.managed_relations){if($relation.relation -cnotin $relations -or !$seenRelations.Add($relation.relation)){throw 'managed_relation_allowlist'};foreach($field in @('table_including_toast_bytes','indexes_bytes','total_bytes')){if(($relation[$field] -isnot [int] -and $relation[$field] -isnot [long]) -or $relation[$field] -lt 0){throw 'managed_physical_bytes_type'}}}
 if(!$report.limitations.Contains('physical bytes may change') -or !$report.limitations.Contains('do not add') -or !$report.limitations.Contains('Not quota') -or !$report.limitations.Contains('WAL') -or !$report.limitations.Contains('filesystem free space')){throw 'operator_scope_limitations'}
 $expected=@{log_state=1;log_data=1;log_source=1;log_analysis=1;model=0;conversion=0}
 if($report.record_counts.Count -ne 6){throw 'record_kind_count'};foreach($kind in $expected.Keys){if(($report.record_counts[$kind] -isnot [int] -and $report.record_counts[$kind] -isnot [long]) -or $report.record_counts[$kind] -ne $expected[$kind]){throw 'manual_record_counts'}}
 Negative 'app90k' '25006';Negative 'empty-report' '22023' 'capacity_minimum_v3_schema_required';Negative 'unknown-report' '22023' 'capacity_unknown_record_kind'
 $capacity=FreshSerialCapacity
 [void](Request 'START child');$held=$false
 foreach($label in @('lock-ready-01','lock-ready-02','lock-ready-03')){[void](Run $label);if((ReadText $label).Trim() -ceq 'CAPACITY_LOCK_HELD_V1'){$held=$true;break}}
 if(!$held){throw 'actual_granted_lock_not_observed'}
 Negative 'http90k' '55P03';[void](WaitCommand 'child')
 [void](Run 'source90k');$sentinel=ReadJson (Join-Path $c.output 'session/source90k.stdout') 65536
 if($sentinel.rows -ne 1 -or $sentinel.minimum -ne 17 -or $sentinel.maximum -ne 17){throw 'sentinel_changed'}
 [void](Request 'SAMPLE postgres');[void](Run 'pg-stop');[void](WaitCommand 'postgres')
 Save 'worker-proof.json' @{status='ACTUAL_BOUNDED_CAPACITY_DIAGNOSTIC_CONTROLS';report=$report;read_only_write_refused=$true;real_granted_lock_timeout=$true;empty_schema_refused=$true;unknown_kind_refused=$true;sentinel_unchanged=$true;serial_capacity=$capacity;no_apps_started=$true}
}catch{Save 'worker-failure.json' @{status='FAILED_PARTIAL_ONLY';type=$_.Exception.GetType().FullName;message=$_.Exception.Message};throw}
