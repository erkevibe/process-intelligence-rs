param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'process-identity.psm1') -Force
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output
$rows=[Collections.Generic.List[object]]::new();$nonzero=$false
for($i=1;$i -le 3;$i++){
 $child=$null;$closed=$false;$job=[PiOwnedJob]::new()
 try{
  $child=Start-OwnedCapturedProcess -Program $c.pwsh -ProgramSha256 $c.pwsh_sha -Arguments @('-NoProfile','-Command',"[Console]::Out.WriteLine('identity-ready'); [void][Console]::In.ReadLine()") -WorkingDirectory $c.workspace -OutputDirectory $c.output -Label ('identity-'+$i) -MaxOutputBytes 1MB -RedirectInput $true
  $job.Assign($child.Handle);if(!$job.Member($child.Handle)){throw 'identity_job'}
  $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$child.Process.Id)
  $creation=[DateTimeOffset]::ParseExact([string]$child.Record.native_creation_utc,'o',[Globalization.CultureInfo]::InvariantCulture)
  [long]$native=[PiS21ProcessTime]::CreationTicks($child.Handle)
  [long]$start=$child.Process.StartTime.ToUniversalTime().Ticks
  [long]$cim=$row.CreationDate.ToUniversalTime().Ticks
  Write-OwnedJson (Join-Path $c.output ('identity-observation-'+$i+'.json')) @{pid=$child.Process.Id;native_ticks=[string]$native;record_ticks=[string]$creation.UtcTicks;starttime_ticks=[string]$start;cim_ticks=[string]$cim;cim_datetime_kind=[string]$row.CreationDate.Kind}
  if($creation.UtcTicks -ne $native -or $start -ne $native -or !(Test-S21CreationIdentity $creation.UtcTicks $native $cim)){throw 'calibration_precision_not_proven'}
  Assert-S21ProcessIdentity $child $c.pwsh $row
  if(($native % 10) -ne 0){$nonzero=$true}
  if(Test-S21CreationIdentity ($native+1) $native $cim){throw 'counter_wrong_native_accepted'}
  if(Test-S21CreationIdentity $native $native ($cim+10)){throw 'counter_wrong_cim_accepted'}
  $wrongPid=[pscustomobject]@{ProcessId=($child.Process.Id+1);CreationDate=$row.CreationDate;ExecutablePath=$row.ExecutablePath;CommandLine=$row.CommandLine}
  $rejected=$false;try{Assert-S21ProcessIdentity $child $c.pwsh $wrongPid}catch{if($_.Exception.Message -cne 'owned_identity_pid'){throw};$rejected=$true};if(!$rejected){throw 'counter_wrong_pid_accepted'}
  $rejected=$false;try{Assert-S21ProcessIdentity $child (Join-Path $c.workspace 'wrong.exe') $row}catch{if($_.Exception.Message -cne 'owned_identity_image'){throw};$rejected=$true};if(!$rejected){throw 'counter_wrong_image_accepted'}
  $rows.Add(@{pid=$child.Process.Id;native_ticks=[string]$native;record_ticks=[string]$creation.UtcTicks;starttime_ticks=[string]$start;cim_ticks=[string]$cim;discarded_100ns_ticks=($native % 10);exact_native_match=$true;exact_integer_cim_floor=$true;wrong_native_rejected=$true;neighbor_microsecond_rejected=$true;wrong_pid_rejected=$true;wrong_image_rejected=$true})
  $child.Process.StandardInput.WriteLine('done');$child.Process.StandardInput.Close()
  if(!$child.Process.WaitForExit(10000)){throw 'identity_child_exit_timeout'}
  $r=Complete-OwnedCapturedProcess $child;$closed=$true
  if($r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'identity_capture'}
 }finally{
  if($child -and !$closed){$job.Stop();if($child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}}
  $job.Dispose()
 }
}
if(!$nonzero){throw 'calibration_no_nonzero_discarded_tick'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'identity-proof.json') @{status='ACTUAL_THREE_OWNED_NATIVE_CIM_PRECISION_CALIBRATION';rows=$rows.ToArray();native_precision_preserved=$true;no_time_tolerance=$true;postgres_tests_not_executed=$true}
