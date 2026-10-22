Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('PiS21ProcessTime' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PiS21ProcessTime {
 [DllImport("kernel32.dll", SetLastError=true)]
 static extern bool GetProcessTimes(IntPtr handle,out long creation,out long exit,out long kernel,out long user);
 public static long CreationTicks(IntPtr handle){
  long c,e,k,u;if(!GetProcessTimes(handle,out c,out e,out k,out u))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  return DateTime.FromFileTimeUtc(c).Ticks;
 }
}
'@
}
function Test-S21CreationIdentity([long]$ExpectedCreationTicks,[long]$HandleCreationTicks,[long]$CimCreationTicks){
 # CIM datetime carries microseconds; retained native handles keep all 100ns ticks.
 # Integer subtraction avoids precision loss in a floating-point division.
 return $ExpectedCreationTicks -eq $HandleCreationTicks -and ($CimCreationTicks % 10) -eq 0 -and ($HandleCreationTicks - ($HandleCreationTicks % 10)) -eq $CimCreationTicks
}
function Assert-S21ProcessIdentity($Child,[string]$Program,$CimRow,[string]$Datadir=''){
 if(!$Child -or !$CimRow -or $Child.Process.HasExited){throw 'owned_identity_not_live'}
 if($Child.Process.Id -ne $Child.Record.pid -or $CimRow.ProcessId -ne $Child.Record.pid){throw 'owned_identity_pid'}
 $creation=[DateTimeOffset]::ParseExact([string]$Child.Record.native_creation_utc,'o',[Globalization.CultureInfo]::InvariantCulture)
 [long]$handleTicks=[PiS21ProcessTime]::CreationTicks($Child.Handle)
 if($Child.Process.StartTime.ToUniversalTime().Ticks -ne $creation.UtcTicks -or !(Test-S21CreationIdentity $creation.UtcTicks $handleTicks $CimRow.CreationDate.ToUniversalTime().Ticks)){throw 'owned_identity_creation'}
 if(!([IO.Path]::GetFullPath([string]$CimRow.ExecutablePath)).Equals([IO.Path]::GetFullPath($Program),[StringComparison]::OrdinalIgnoreCase)){throw 'owned_identity_image'}
 if($Datadir){[void](Get-OwnedDatadirArgument ([string]$CimRow.CommandLine) $Datadir)}
 if($Child.Process.HasExited){throw 'owned_identity_exited_during_read'}
}
Export-ModuleMember -Function Test-S21CreationIdentity,Assert-S21ProcessIdentity
