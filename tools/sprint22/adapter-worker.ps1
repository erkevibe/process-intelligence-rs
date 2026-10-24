param([Parameter(Mandatory)][string]$Ipc,[Parameter(Mandatory)][ValidateSet('service','absolute','memory')][string]$Scenario,[Parameter(Mandatory)][string]$ExpectedImage,[Parameter(Mandatory)][string]$Output)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::Write("adapter-worker`n");[Console]::Error.Write("adapter-error`n")
$sequence=0
function Request([string]$Line){
 $script:sequence++;if($script:sequence -gt 32){throw 'adapter_request_bound'}
 $base=Join-Path $Ipc ('{0:D6}' -f $script:sequence);$b=[Text.Encoding]::ASCII.GetBytes($Line+"`n")
 $f=[IO.File]::Open(($base+'.reqdata'),'CreateNew','Write','Read');try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()}
 $f=[IO.File]::Open(($base+'.req'),'CreateNew','Write','Read');try{$f.WriteByte(1);$f.Flush($true)}finally{$f.Dispose()}
 $end=[DateTimeOffset]::UtcNow.AddSeconds(40)
 while(!(Test-Path -LiteralPath ($base+'.ack'))){if([DateTimeOffset]::UtcNow -ge $end){throw 'adapter_ack_timeout'};Start-Sleep -Milliseconds 20}
 if((Get-Item -LiteralPath ($base+'.ackdata')).Length -gt 65536){throw 'adapter_ack_bound'}
 return (Get-Content -LiteralPath ($base+'.ackdata') -Raw|ConvertFrom-Json -AsHashtable)
}
$r=Request 'START child'
if($Scenario -in @('service','absolute')){Start-Sleep -Seconds 5;throw 'expected_independent_stop_missing'}
Add-Type -Path (Join-Path $PSScriptRoot 'MemoryProbe.cs')
$wrongPath=Join-Path $Output 'wrong-identity.ndjson';$wrongRefused=$false
try{$wrong=[S22MemoryProbe]::new([uint32]$r.pid,([long]$r.creation_filetime+1),$ExpectedImage,$wrongPath);$wrong.Dispose();throw 'wrong_identity_accepted'}catch{if($_.Exception.ToString() -notmatch 'memory_native_creation_mismatch'){throw};$wrongRefused=$true}
if(Test-Path -LiteralPath $wrongPath){throw 'wrong_identity_output_created'}
$path=Join-Path $Output 'memory.ndjson';$probe=[S22MemoryProbe]::new([uint32]$r.pid,[long]$r.creation_filetime,$ExpectedImage,$path)
try{$probe.SetStage('warm_before');Start-Sleep -Milliseconds 500}finally{$probe.Dispose()}
if($probe.Fault -or !$probe.Completed -or $probe.Count -lt 2){throw 'memory_fixture_complete_required'}
$proof=@{pid=$r.pid;creation_filetime=$r.creation_filetime;samples=$probe.Count;sha256=(Get-FileHash -LiteralPath $path).Hash;complete=$probe.Completed;fault=$probe.Fault;wrong_identity_refused=$wrongRefused}
$deadPath=Join-Path $Output 'dead-target.ndjson';$dead=[S22MemoryProbe]::new([uint32]$r.pid,[long]$r.creation_filetime,$ExpectedImage,$deadPath)
[void](Request 'KILL child');$r=Request 'STATUS child'
while(!$r.exited){Start-Sleep -Milliseconds 100;$r=Request 'STATUS child'}
$dead.Dispose();if(!$dead.Fault -or $dead.Completed){throw 'dead_target_false_complete'}
$proof.dead_target_partial=$true;$proof.dead_target_fault=$dead.FaultCode;$proof.dead_target_sha256=(Get-FileHash $deadPath).Hash
$b=[Text.UTF8Encoding]::new($false).GetBytes(($proof|ConvertTo-Json));$f=[IO.File]::Open((Join-Path $Output 'memory-proof.json'),'CreateNew','Write','Read');try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()}
if($r.native_exit -ne 137){throw 'memory_fixture_child_exit'}
exit 0
