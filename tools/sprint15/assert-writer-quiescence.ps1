[CmdletBinding(DefaultParameterSetName='Check')]
param(
 [Parameter(Mandatory,ParameterSetName='Check')][string]$RequestPath,
 [Parameter(Mandatory,ParameterSetName='Check')][string]$RequestSha256,
 [Parameter(Mandatory,ParameterSetName='Check')][string[]]$AckPaths,
 [Parameter(Mandatory,ParameterSetName='Check')][string[]]$AckSha256,
 [Parameter(ParameterSetName='SelfTest')][switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# The caller must also receive each actual agent's AFTER-TOOL message confirming
# ACK writer completion. File visibility alone is not that message boundary.
# Root performs no writes between this admission and native baseline completion.
function Utc([string]$s){if($s -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?Z$'){throw 'quiescence_literal_utc'};[DateTimeOffset]::Parse($s,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime}
function Validate($r,$acks,[string]$requestSha,[DateTime]$now){
 if($r.kind -cne 'S15_WRITER_QUIESCENCE_REQUEST' -or $r.nonce -cnotmatch '^[a-f0-9]{32}$' -or $requestSha -cnotmatch '^[A-F0-9]{64}$' -or $r.config_sha256 -cnotmatch '^[A-F0-9]{64}$' -or $r.output_directory -isnot [string] -or !$r.output_directory -or $r.other_agents_suspended -isnot [bool] -or !$r.other_agents_suspended -or $r.root_will_not_write_during_baseline -isnot [bool] -or !$r.root_will_not_write_during_baseline){throw 'quiescence_request_identity'}
 $time=Utc $r.utc;if($time -gt $now -or ($now-$time).TotalMinutes -gt 10){throw 'quiescence_request_stale'}
 $roles=@($r.writers);if(($roles|Sort-Object)-join ',' -cne 'PM,QA,Root,TD' -or $roles.Count -ne 4 -or @($acks).Count -ne 4){throw 'quiescence_exact_writer_roster'}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($a in $acks){if(!$seen.Add($a.author_role) -or $a.author_role -cnotin $roles -or $a.kind -cne 'S15_WRITER_QUIESCENCE_ACK' -or $a.request_sha256 -cne $requestSha -or $a.nonce -cne $r.nonce -or $a.config_sha256 -cne $r.config_sha256 -or $a.output_directory -cne $r.output_directory -or $a.no_inflight_tool_or_checker -isnot [bool] -or !$a.no_inflight_tool_or_checker -or $a.no_writes_until_baseline_done -isnot [bool] -or !$a.no_writes_until_baseline_done){throw 'quiescence_missing_busy_or_wrong_ack'};$at=Utc $a.utc;if($at -lt $time -or $at -gt $now){throw 'quiescence_ack_time'}}
}
if($SelfTest){
 $now=[DateTimeOffset]::Parse('2026-10-20T11:00:00Z').UtcDateTime;$sha='A'*64
 $r=@{kind='S15_WRITER_QUIESCENCE_REQUEST';nonce='b'*32;config_sha256='C'*64;output_directory='synthetic';utc='2026-10-20T10:59:00Z';writers=@('Root','QA','TD','PM');other_agents_suspended=$true;root_will_not_write_during_baseline=$true}
 $acks=@($r.writers|ForEach-Object {@{kind='S15_WRITER_QUIESCENCE_ACK';author_role=$_;request_sha256=$sha;nonce=$r.nonce;config_sha256=$r.config_sha256;output_directory=$r.output_directory;utc='2026-10-20T10:59:10Z';no_inflight_tool_or_checker=$true;no_writes_until_baseline_done=$true}})
 Validate $r $acks $sha $now;$count=1
 foreach($case in @('missing','duplicate','wrongrole','nonce','requestsha','profile','output','busy','write','early','future','local','stale','otheragents','string-busy','string-write','string-suspended','string-root')){
  $rr=$r|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable -DateKind String;$aa=@($acks|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable -DateKind String)
  switch($case){missing{$aa=$aa[0..2]} duplicate{$aa[3].author_role='QA'} wrongrole{$aa[3].author_role='Customer'} nonce{$aa[0].nonce='d'*32} requestsha{$aa[0].request_sha256='E'*64} profile{$aa[0].config_sha256='F'*64} output{$aa[0].output_directory='wrong'} busy{$aa[0].no_inflight_tool_or_checker=$false} write{$aa[0].no_writes_until_baseline_done=$false} early{$aa[0].utc='2026-10-20T10:58:59Z'} future{$aa[0].utc='2026-10-20T11:00:01Z'} local{$aa[0].utc='2026-10-20T15:59:10+05:00'} stale{$rr.utc='2026-10-20T10:00:00Z'} otheragents{$rr.other_agents_suspended=$false} string-busy{$aa[0].no_inflight_tool_or_checker='false'} string-write{$aa[0].no_writes_until_baseline_done='false'} string-suspended{$rr.other_agents_suspended='false'} string-root{$rr.root_will_not_write_during_baseline='false'}}
  $rejected=$false;try{Validate $rr $aa $sha $now}catch{$rejected=$true};if(!$rejected){throw ('quiescence_negative_failed_'+$case)};$count++
 }
 @{status='PURE_WRITER_BARRIER_REGRESSION_PASSED';checks=$count;no_files_children_or_pg=$true}|ConvertTo-Json -Compress;exit 0
}
$prefix=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../.local/sprint14')).TrimEnd('\')+'\'
function ReadPin([string]$p,[string]$sha){$p=[IO.Path]::GetFullPath($p);$f=Get-Item -LiteralPath $p;if(!$p.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $f.PSIsContainer -or $f.Attributes -band [IO.FileAttributes]::ReparsePoint -or $f.Length -gt 64KB -or $sha -cnotmatch '^[A-F0-9]{64}$' -or (Get-FileHash -LiteralPath $p).Hash -cne $sha){throw 'quiescence_pinned_metadata'};Get-Content -LiteralPath $p -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
if($AckPaths.Count -ne $AckSha256.Count){throw 'quiescence_pin_count'};$r=ReadPin $RequestPath $RequestSha256;$acks=@();for($i=0;$i -lt $AckPaths.Count;$i++){$acks+=,(ReadPin $AckPaths[$i] $AckSha256[$i])}
Validate $r $acks $RequestSha256 ([DateTime]::UtcNow)
@{status='ALL_ACTUAL_WRITER_ACKS_VERIFIED_BEFORE_LAUNCH';request_sha256=$RequestSha256;config_sha256=$r.config_sha256;nonce=$r.nonce;writers=$r.writers;limits=@('Caller must additionally receive all actual post-tool completion messages; file visibility alone is insufficient','Caller admission only; does not prevent an external writer','Strict fresh native two-pass meter remains mandatory','No process or PostgreSQL start/stop is performed')}|ConvertTo-Json -Depth 5 -Compress
