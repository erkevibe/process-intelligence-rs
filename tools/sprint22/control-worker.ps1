param([Parameter(Mandatory)][string]$Ipc)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::Write("worker-ready`n");[Console]::Error.Write("worker-error`n")
$sequence=0
function Request([string]$Line){
 $script:sequence++
 if($script:sequence -gt 512){throw 'worker_request_limit'}
 $base=Join-Path $Ipc ('{0:D6}' -f $script:sequence)
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Line+"`n")
 $f=[IO.File]::Open(($base+'.reqdata'),'CreateNew','Write','Read');try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
 $f=[IO.File]::Open(($base+'.req'),'CreateNew','Write','Read');try{$f.WriteByte(1);$f.Flush($true)}finally{$f.Dispose()}
 $end=[DateTimeOffset]::UtcNow.AddSeconds(40)
 while(!(Test-Path -LiteralPath ($base+'.ack'))){if([DateTimeOffset]::UtcNow -ge $end){throw 'worker_ack_timeout'};Start-Sleep -Milliseconds 20}
 if((Get-Item -LiteralPath ($base+'.ackdata')).Length -gt 65536){throw 'worker_ack_bound'}
 return (Get-Content -LiteralPath ($base+'.ackdata') -Raw|ConvertFrom-Json -AsHashtable)
}
$r=Request 'START child'
while(!$r.exited){Start-Sleep -Milliseconds 100;$r=Request 'STATUS child'}
if($r.native_exit -ne 0){throw 'child_nonzero'}
exit 0
