param([Parameter(Mandatory)][string]$Ipc,[Parameter(Mandatory)][string]$TaskConfig,[Parameter(Mandatory)][string]$TaskConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $TaskConfig).Hash -cne $TaskConfigSha){throw 'worker_config_pin'}
$c=Get-Content -LiteralPath $TaskConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$sequence=0
function ReadJson([string]$Path,[long]$Cap=2MB){
 if($Cap -lt 1 -or $Cap -gt 2MB){throw 'json_cap'}
 $f=[IO.File]::Open($Path,'Open','Read','ReadWrite')
 try{$buffer=[byte[]]::new([int]$Cap+1);$used=0;while($used -lt $buffer.Length){$n=$f.Read($buffer,$used,$buffer.Length-$used);if($n -eq 0){break};$used+=$n};if($used -gt $Cap){throw 'json_bound'};$raw=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$used)}finally{$f.Dispose()}
 return ($raw|ConvertFrom-Json -AsHashtable -DateKind String)
}
function Save([string]$Name,[object]$Value){$b=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 20));if($b.Length -gt 2MB){throw 'worker_proof_bound'};$f=[IO.File]::Open((Join-Path $c.output $Name),'CreateNew','Write','Read');try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()}}
function Request([string]$Line,[int]$AckSeconds=40){if($AckSeconds -lt 1 -or $AckSeconds -gt 100){throw 'ack_deadline_bound'};$script:sequence++;if($script:sequence -gt 512){throw 'worker_request_limit'};$base=Join-Path $Ipc ('{0:D6}' -f $script:sequence);$b=[Text.Encoding]::ASCII.GetBytes($Line+"`n");$f=[IO.File]::Open(($base+'.reqdata'),'CreateNew','Write','Read');try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()};$f=[IO.File]::Open(($base+'.req'),'CreateNew','Write','Read');try{$f.WriteByte(1);$f.Flush($true)}finally{$f.Dispose()};$end=[DateTimeOffset]::UtcNow.AddSeconds($AckSeconds);while(!(Test-Path -LiteralPath ($base+'.ack'))){if([DateTimeOffset]::UtcNow -ge $end){throw 'worker_ack_timeout'};Start-Sleep -Milliseconds 20};$r=ReadJson ($base+'.ackdata') 65536;if($r.sequence -ne $script:sequence){throw 'ack_sequence'};return $r}
function WaitCommand([string]$Label,[int[]]$Allowed=@(0)){$r=Request ('STATUS '+$Label);while(!$r.exited){Start-Sleep -Seconds 2;$r=Request ('STATUS '+$Label)};if($r.native_exit -notin $Allowed){throw ('native_nonzero_'+$Label)};# Local immutable-receipt consumer barrier, not a generic protocol change.
 $r=Request ('STATUS '+$Label);$p=ReadJson (Join-Path $c.output ('session/'+$Label+'.process.json')) 65536;if($p.pid -ne $r.pid -or $p.native_creation_filetime -ne $r.creation_filetime -or $p.native_exit -ne $r.native_exit -or !$p.stdout_complete -or !$p.stderr_complete -or $p.source_status -cne 'captured'){throw 'complete_receipt_required'};return $r}
function Run([string]$Label,[int[]]$Allowed=@(0)){[void](Request ('START '+$Label));return (WaitCommand $Label $Allowed)}

foreach($command in $c.commands){[void](Run $command.label);Save ('checkpoint-'+$command.label+'.json') @{status='NATIVE_COMMAND_CLOSED';label=$command.label}}
Save 'worker-proof.json' @{status='S27_FINITE_COMPARISON_COMMANDS_PASS';commands=$c.commands.Count}