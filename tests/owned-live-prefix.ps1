param([Parameter(Mandatory)][string]$Output,[Parameter(Mandatory)][string]$Node,[Parameter(Mandatory)][string]$NodeSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../tools/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../tools/owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $Output
$eventPath=Join-Path $Output 'live-events.jsonl'
$scriptText='const fs=require("node:fs");const fd=fs.openSync(process.env.PI_TEST_EVENT,"wx");fs.writeSync(fd,JSON.stringify({event:"listener_ready"})+"\n");setTimeout(()=>{},60000)'
$writer=Start-OwnedCapturedProcess -Program $Node -ProgramSha256 $NodeSha -Arguments @('-e',$scriptText) -WorkingDirectory (Split-Path -Parent $PSScriptRoot) -OutputDirectory $Output -Label 'writer' -MaxOutputBytes 1MB -Environment @{PI_TEST_EVENT=$eventPath}
try {
    $until=[DateTime]::UtcNow.AddSeconds(10)
    while(-not(Test-Path -LiteralPath $eventPath)){if($writer.Process.HasExited -or [DateTime]::UtcNow -ge $until){throw 'writer_not_ready'};Start-Sleep -Milliseconds 100}
    $ordinaryFailed=$false
    try{[void][IO.File]::ReadAllText($eventPath)}catch{$ordinaryFailed=$true}
    $prefix=Get-OwnedLivePrefix $eventPath
    if(-not $ordinaryFailed -or -not $prefix.Contains('"event":"listener_ready"') -or $writer.Process.HasExited){throw 'live_shared_reader_regression'}
    $boundedRefused=$false
    try{[void](Get-OwnedLivePrefix $eventPath 1)}catch{$boundedRefused=$true}
    if(-not $boundedRefused){throw 'live_prefix_bound_regression'}
    Write-OwnedJson (Join-Path $Output 'prefix-result.json') @{utc=[DateTime]::UtcNow.ToString('o');writer_pid=$writer.Process.Id;writer_creation_utc=$writer.Record.native_creation_utc;ordinary_read_sharing_refused=$ordinaryFailed;bounded_shared_prefix_ready=$true;writer_still_alive=$true;oversized_read_refused=$true;scope='Actual Node wx writer left open, read-only finite prefix, no completed stream claim'}
} finally {
    if(-not $writer.Process.HasExited){$writer.Process.Kill($true);[void]$writer.Process.WaitForExit(10000)}
    [void](Complete-OwnedCapturedProcess $writer)
}
