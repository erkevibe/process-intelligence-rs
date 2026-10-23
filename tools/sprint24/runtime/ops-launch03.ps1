param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PWD 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $Config $ConfigSha
$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if([string]$PWD -cne $c.workspace -or [DateTimeOffset]$c.deadline_utc -gt [DateTimeOffset]'2026-10-23T22:45:20Z' -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.deadline_utc -or $c.outer_seconds -gt 1800){throw 'calendar_launch_scope'}
if($c.phase -cne (Join-Path $PSScriptRoot 'ops-phase03.ps1') -or $c.output -cne (Join-Path $c.workspace '.local/sprint21/root/sprint24/ops02') -or $c.session_seconds -lt 1 -or $c.session_seconds -gt 1680){throw 'stock_crash_launch_scope'}
foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256}
$out=New-OwnedPrivateDirectory $c.output
$job=[PiOwnedJob]::new();$child=$null;$done=$false;$nonce=[Guid]::NewGuid().ToString('N')
try{
 $child=Start-OwnedCapturedProcess -Program $c.pwsh -ProgramSha256 $c.pwsh_sha -Arguments @('-NoProfile','-File',$c.phase,'-Config',$Config,'-ConfigSha',$ConfigSha,'-Nonce',$nonce) -WorkingDirectory $c.workspace -OutputDirectory $out -Label collector -MaxOutputBytes 65536 -Environment @{TEMP=$c.temp;TMP=$c.temp} -RedirectInput $true
 $job.Assign($child.Handle);if(!$job.Member($child.Handle)){throw 'collector_outer_job'}
 $child.Process.StandardInput.WriteLine('GO '+$nonce);$child.Process.StandardInput.Close()
 $end=[DateTimeOffset]::UtcNow.AddSeconds($c.outer_seconds)
 while(!$child.Process.WaitForExit(100)){if([DateTimeOffset]::UtcNow -ge $end -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.deadline_utc -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){$job.Stop();if(!$child.Process.WaitForExit(10000)){throw 'collector_stop_unknown'};throw 'collector_outer_bound_no_inner_capture_guarantee'}}
 $r=Complete-OwnedCapturedProcess $child;$done=$true
 if($r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault){throw 'collector_failed'}
 Write-OwnedJson (Join-Path $out 'launch-result.json') @{status='ACTUAL_FINITE_OPS_COLLECTOR_CLOSED';native_exit=$r.native_exit;both_eof=$true;config_sha256=$ConfigSha;utc=[DateTimeOffset]::UtcNow.ToString('o');outer_job_scope='watchdog only; collector death does not prove inner captures'}
}finally{if($child -and !$done){$job.Stop();if($child.Process.WaitForExit(10000)){try{[void](Complete-OwnedCapturedProcess $child)}catch{Write-Warning 'collector_capture_finalization_failed'}}};$job.Dispose()}
