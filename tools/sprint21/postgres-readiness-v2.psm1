Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Caller imports the pinned owned-runtime module and owns the outer native job.
function Wait-S21PostgresReady($Config,$Server,[int]$Seconds=20){
 if($Seconds -lt 1 -or $Seconds -gt 20 -or $Config.pg_port -ne 55448){throw 'postgres_readiness_bounds'}
 Assert-OwnedHash $Config.pg_isready $Config.pg_isready_sha
 Assert-OwnedPrivateDirectory $Config.output
 $until=[DateTimeOffset]::UtcNow.AddSeconds($Seconds)
 $freeze=[DateTimeOffset]$Config.phase_deadline_utc
 for($attempt=1;$attempt -le 12;$attempt++){
  if([DateTimeOffset]::UtcNow -ge $until -or [DateTimeOffset]::UtcNow -ge $freeze -or (Get-PSDrive C).Free -lt 8GB){throw 'postgres_readiness_deadline_or_free_floor'}
  if(!$Server -or $Server.Process.HasExited -or $Server.OutCapture.LimitReached -or $Server.ErrCapture.LimitReached -or $Server.OutCapture.Pump.IsFaulted -or $Server.ErrCapture.Pump.IsFaulted){throw 'postgres_readiness_server_exit_or_capture_fault'}
  $label='readiness-'+('{0:D2}' -f $attempt)
  $child=Start-OwnedCapturedProcess -Program $Config.pg_isready -ProgramSha256 $Config.pg_isready_sha -Arguments @('-h','127.0.0.1','-p',[string]$Config.pg_port,'-U','pi_s21_admin','-d','postgres','-t','1') -WorkingDirectory $Config.workspace -OutputDirectory $Config.output -Label $label -MaxOutputBytes 64KB
  $probeUntil=[DateTimeOffset]::UtcNow.AddSeconds(3);$stopped=$false
  while(!$child.Process.WaitForExit(50)){
   if([DateTimeOffset]::UtcNow -ge $probeUntil -or [DateTimeOffset]::UtcNow -ge $until -or [DateTimeOffset]::UtcNow -ge $freeze -or $Server.Process.HasExited -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){
    $stopped=$true;$child.Process.Kill($true)
    if(!$child.Process.WaitForExit(10000)){throw 'postgres_readiness_owned_probe_stop_timeout'}
    break
   }
  }
  $r=Complete-OwnedCapturedProcess $child
  if($stopped -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'postgres_readiness_probe_capture_or_timeout'}
  if($r.native_exit -eq 0){
   if($Server.Process.HasExited -or [DateTimeOffset]::UtcNow -ge $until -or [DateTimeOffset]::UtcNow -ge $freeze){throw 'postgres_readiness_expired_after_probe'}
   $proof=@{status='ACTUAL_PG_ISREADY_ACCEPTING_CONNECTIONS';attempts=$attempt;native_exit=0;last_probe_label=$label;per_probe_seconds=3;maximum_probes=12;maximum_wait_seconds=$Seconds;all_probe_streams_eof=$true;sql_or_recovery_state_not_claimed=$true;utc=[DateTimeOffset]::UtcNow.ToString('o')}
   Write-OwnedJson (Join-Path $Config.output 'postgres-readiness-proof.json') $proof
   return $proof
  }
  if($r.native_exit -notin @(1,2)){throw 'postgres_readiness_unexpected_native_exit'}
  Start-Sleep -Milliseconds 200
 }
 throw 'postgres_readiness_twelve_probe_limit'
}
Export-ModuleMember -Function Wait-S21PostgresReady
