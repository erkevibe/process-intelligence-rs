# Finite monotonic sampling schedule shared by the helper and causal regression.
Set-StrictMode -Version Latest
function Get-OwnedObservationDue([hashtable]$State,[double]$ElapsedMilliseconds){
 if([double]::IsNaN($ElapsedMilliseconds) -or [double]::IsInfinity($ElapsedMilliseconds) -or $ElapsedMilliseconds -lt 0 -or $State.maximum_attempts -ne 30 -or $State.interval_ms -ne 1000 -or $State.attempts -lt 0 -or $State.attempts -gt 30){throw 'observation_schedule_bounds'}
 if($State.attempts -lt $State.maximum_attempts -and $ElapsedMilliseconds -ge $State.next_ms){
  $State.attempts++;$State.next_ms=$ElapsedMilliseconds+$State.interval_ms;return $true
 }
 return $false
}
Export-ModuleMember -Function Get-OwnedObservationDue
