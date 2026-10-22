# Capacity-only read of the same FILE_STANDARD_INFO native counters used by
# PiS13EvidenceStorageV1.Inspect. No compression/volume queries or mutations.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('PiS20CapacityStorage' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PiS20CapacityStorage {
 [StructLayout(LayoutKind.Sequential)] public struct StandardInfo {
  public long AllocationSize; public long EndOfFile; public uint NumberOfLinks;
  [MarshalAs(UnmanagedType.U1)] public bool DeletePending;
  [MarshalAs(UnmanagedType.U1)] public bool Directory;
 }
 [DllImport("kernel32.dll",SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int kind,out StandardInfo info,uint size);
 public static StandardInfo Inspect(FileStream stream){
  if(Marshal.SizeOf<StandardInfo>()!=24 || Marshal.OffsetOf<StandardInfo>("EndOfFile").ToInt32()!=8 || Marshal.OffsetOf<StandardInfo>("Directory").ToInt32()!=21) throw new InvalidOperationException("capacity_native_abi");
  StandardInfo value;
  if(!GetFileInformationByHandleEx(stream.SafeFileHandle,1,out value,24)) throw new Win32Exception(Marshal.GetLastWin32Error(),"FileStandardInfo");
  if(value.Directory || value.DeletePending || value.EndOfFile<0 || value.AllocationSize<0 || value.NumberOfLinks==0) throw new InvalidOperationException("capacity_native_invalid_file");
  return value;
 }
}
'@
}
