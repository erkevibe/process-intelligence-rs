param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$ConfigSha256)
$ErrorActionPreference='Stop'
if ((Get-FileHash -LiteralPath $ConfigPath).Hash -cne $ConfigSha256.ToUpperInvariant()) { throw 'config_sha_before_import' }
$c=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
foreach ($pin in @(@((Join-Path $PSScriptRoot 'public-service-runtime.psm1'),$c.module_sha256),@($PSCommandPath,$c.worker_sha256),@((Get-Process -Id $PID).Path,$c.pwsh_sha256))) {
    if ($pin[1] -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $pin[0]).Hash -cne $pin[1].ToUpperInvariant()) { throw 'worker_source_before_import' }
}
Import-Module (Join-Path $PSScriptRoot 'public-service-runtime.psm1') -Force -DisableNameChecking
$line=[Console]::In.ReadLineAsync()
if (-not $line.Wait(30000) -or $line.Result -cne ('GO '+$ConfigSha256.ToUpperInvariant())) { throw 'owned_go_required' }
$eof=[Console]::In.ReadLineAsync()
if (-not $eof.Wait(3000) -or $null -ne $eof.Result) { throw 'owned_go_eof' }
Assert-OwnedHash $ConfigPath $ConfigSha256
Assert-OwnedHash $c.program $c.program_sha256
foreach ($pin in $c.inputs) { Assert-OwnedHash $pin.path $pin.sha256 }
$child=Start-OwnedCapturedProcess -Program $c.program -ProgramSha256 $c.program_sha256 -Arguments $c.arguments -WorkingDirectory $c.cwd -OutputDirectory $c.output_directory -Label 'child' -MaxOutputBytes $c.max_output_bytes -Environment $c.environment
$record=[ordered]@{config_sha256=$ConfigSha256.ToUpperInvariant();child_pid=$child.Process.Id;native_creation_utc=$child.Record.native_creation_utc;scope='Native command launched after outer exact Job assignment and GO; child exit and captures separate from coordinator'}
Write-OwnedJson (Join-Path $c.output_directory 'worker-admission.json') $record
# Outer supervisor owns the timeout, capacity, freeze and descendant teardown.
$forced=$false
try {
    while (-not $child.Process.WaitForExit(100)) {
        if ($child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted -or $child.OutCapture.Pump.IsCanceled -or $child.ErrCapture.Pump.IsCanceled) {
            $forced=$true
            Write-OwnedJson (Join-Path $c.output_directory 'worker-stop.json') @{reason='child_output_or_capture_stop';child_pid=$child.Process.Id;stdout_bytes=$child.OutCapture.Bytes;stderr_bytes=$child.ErrCapture.Bytes;limit=$c.max_output_bytes}
            # Only the native command launched by this worker and its descendants.
            $child.Process.Kill($true)
            if (-not $child.Process.WaitForExit(10000)) { throw 'owned_child_stop_timeout' }
            break
        }
    }
} finally {
    if ($child.Process.HasExited) { $r=Complete-OwnedCapturedProcess $child }
}
if ($forced) { exit 4 }
if (-not $r.stdout_complete -or -not $r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout) { exit 3 }
exit $r.native_exit
