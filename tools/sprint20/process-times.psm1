# Native lifetime CPU for the retained, owned process handle. Not engine-only CPU.
# https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('PiS20ProcessTimes' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PiS20ProcessTimes {
 [StructLayout(LayoutKind.Sequential)] struct Time {public uint Low,High;public ulong Value(){return ((ulong)High<<32)|Low;}}
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out Time created,out Time exited,out Time kernel,out Time user);
 public static ulong[] Read(IntPtr process){
  Time c,e,k,u;if(!GetProcessTimes(process,out c,out e,out k,out u))throw new InvalidOperationException("process_times:"+Marshal.GetLastWin32Error());
  return new[]{c.Value(),e.Value(),k.Value(),u.Value()};
 }
}
'@
}
function Get-S20ProcessTimes([IntPtr]$Handle,[bool]$Exited=$false){
 $values=[PiS20ProcessTimes]::Read($Handle)
 $exitValue=if($Exited){$values[1]}else{$null}
 return @{creation_filetime_100ns=$values[0];exit_filetime_100ns=$exitValue;kernel_cpu_100ns=$values[2];user_cpu_100ns=$values[3];scope='Native GetProcessTimes for actual retained process handle; creation/exit are Windows FILETIME (exit unavailable while alive); CPU since process creation through snapshot, not engine-only CPU.'}
}
Export-ModuleMember -Function Get-S20ProcessTimes
