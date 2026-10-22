Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Invoke-OwnedPhaseCommand([string]$Program,[string]$Sha,[string[]]$Arguments,[string]$Directory,[string]$Output,[string]$Label,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=16MB) {
    $p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $Directory -OutputDirectory $Output -Label $Label -MaxOutputBytes $Cap -Environment $Environment
    $end=[DateTime]::UtcNow.AddSeconds($Seconds);$stopped=$false
    while (-not $p.Process.WaitForExit(100)) {
        if ([DateTime]::UtcNow -ge $end -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted) {
            $stopped=$true;$p.Process.Kill($true);if (-not $p.Process.WaitForExit(10000)) { throw 'phase_child_stop' };break
        }
    }
    $r=Complete-OwnedCapturedProcess $p
    if ($stopped -or $r.native_exit -ne 0 -or -not $r.stdout_complete -or -not $r.stderr_complete -or $r.output_limit -or $r.capture_fault) { throw ('phase_command_failed_'+$Label) }
    return $r
}
Export-ModuleMember -Function Invoke-OwnedPhaseCommand
