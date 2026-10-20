# S14 benign synthetic storage calibration ONLY. Import defines types/functions;
# no filesystem mutation, Win32 call, process launch or compression happens on import.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('PiS13EvidenceStorageV1' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PiS13EvidenceStorageV1 {
 public const uint SetCompressionCode=639040;
 public const uint GetCompressionCode=589884;
 [StructLayout(LayoutKind.Sequential)] public struct StandardInfo {
  public long AllocationSize; public long EndOfFile; public uint NumberOfLinks;
  [MarshalAs(UnmanagedType.U1)] public bool DeletePending;
  [MarshalAs(UnmanagedType.U1)] public bool Directory;
 }
 [StructLayout(LayoutKind.Sequential)] public struct HandleInfo {
  public uint Attributes; public uint CreationLow; public uint CreationHigh;
  public uint AccessLow; public uint AccessHigh; public uint WriteLow; public uint WriteHigh;
  public uint VolumeSerial; public uint SizeHigh; public uint SizeLow; public uint Links;
  public uint IndexHigh; public uint IndexLow;
 }
 // FILE_COMPRESSION_INFO is a separate native metric. It does not rename or
 // replace FILE_STANDARD_INFO.AllocationSize, and is not a budget verdict.
 [StructLayout(LayoutKind.Sequential)] public struct CompressionInfo {
  public long CompressedFileSize; public ushort CompressionFormat;
  public byte CompressionUnitShift; public byte ChunkShift; public byte ClusterShift;
  public byte Reserved0; public byte Reserved1; public byte Reserved2;
 }
 public sealed class Witness {
  public long AllocationSize; public long EndOfFile; public uint Links;
  public string VolumeId; public string FileId; public uint Attributes;
  public string FinalPath; public string FileSystem; public uint FileSystemFlags;
  public ushort CompressionFormat;
  public CompressionInfo FileCompressionInfo;
  public string AllocationSizeSource="FileStandardInfo.AllocationSize";
  public string CompressedFileSizeSource="FileCompressionInfo.CompressedFileSize";
  public bool PhysicalMetricSelectionRequiresIndependentReview=true;
 }
 public sealed class Operation {
  public bool ApiReturnedTrue; public int Win32Error; public int Win32LastErrorRaw; public uint BytesReturned;
  public ushort RequestedFormat; public uint ControlCode;
 }
 [DllImport("kernel32.dll",SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h,int kind,out StandardInfo info,uint size);
 [DllImport("kernel32.dll",SetLastError=true,EntryPoint="GetFileInformationByHandleEx")]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetCompressionInformation(SafeFileHandle h,int kind,out CompressionInfo info,uint size);
 [DllImport("kernel32.dll",SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out HandleInfo info);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder path,uint length,uint flags);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetVolumeInformationByHandleW(SafeFileHandle h,StringBuilder name,uint nameSize,out uint serial,out uint maxComponent,out uint flags,StringBuilder fs,uint fsSize);
 [DllImport("kernel32.dll",SetLastError=true,EntryPoint="DeviceIoControl")]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool SetCompression(SafeFileHandle h,uint code,ref ushort input,uint inputSize,IntPtr output,uint outputSize,out uint returned,IntPtr overlapped);
 [DllImport("kernel32.dll",SetLastError=true,EntryPoint="DeviceIoControl")]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetCompression(SafeFileHandle h,uint code,IntPtr input,uint inputSize,out ushort output,uint outputSize,out uint returned,IntPtr overlapped);
 public static Operation Set(FileStream stream,ushort format){
  if(format!=0 && format!=1) throw new InvalidOperationException("synthetic_format_only");
  uint returned; bool ok=SetCompression(stream.SafeFileHandle,SetCompressionCode,ref format,2,IntPtr.Zero,0,out returned,IntPtr.Zero);
  int error=Marshal.GetLastWin32Error();
  return new Operation{ApiReturnedTrue=ok,Win32Error=ok?0:error,Win32LastErrorRaw=error,BytesReturned=returned,RequestedFormat=format,ControlCode=SetCompressionCode};
 }
 public static Witness Inspect(FileStream stream){
  StandardInfo s; HandleInfo b; CompressionInfo c;
  if(!GetFileInformationByHandleEx(stream.SafeFileHandle,1,out s,(uint)Marshal.SizeOf<StandardInfo>())) throw new Win32Exception(Marshal.GetLastWin32Error(),"FileStandardInfo");
  if(!GetCompressionInformation(stream.SafeFileHandle,8,out c,(uint)Marshal.SizeOf<CompressionInfo>())) throw new Win32Exception(Marshal.GetLastWin32Error(),"FileCompressionInfo");
  if(!GetFileInformationByHandle(stream.SafeFileHandle,out b)) throw new Win32Exception(Marshal.GetLastWin32Error(),"FileIdentity");
  var path=new StringBuilder(32768); uint n=GetFinalPathNameByHandleW(stream.SafeFileHandle,path,(uint)path.Capacity,0);
  if(n==0 || n>=path.Capacity) throw new InvalidOperationException("final_path_unavailable");
  var volume=new StringBuilder(261); var fs=new StringBuilder(261); uint serial,max,flags;
  if(!GetVolumeInformationByHandleW(stream.SafeFileHandle,volume,(uint)volume.Capacity,out serial,out max,out flags,fs,(uint)fs.Capacity)) throw new Win32Exception(Marshal.GetLastWin32Error(),"VolumeInformation");
  ushort format; uint returned;
  if(!GetCompression(stream.SafeFileHandle,GetCompressionCode,IntPtr.Zero,0,out format,2,out returned,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(),"GetCompression");
  if(returned!=2 || s.DeletePending || s.Directory || s.EndOfFile<0 || s.AllocationSize<0 || s.NumberOfLinks!=b.Links || serial!=b.VolumeSerial || s.EndOfFile!=(((long)b.SizeHigh<<32)|b.SizeLow)) throw new InvalidOperationException("inconsistent_file_witness");
  if(c.CompressedFileSize<0 || c.CompressionFormat!=format) throw new InvalidOperationException("inconsistent_compression_information");
  return new Witness{AllocationSize=s.AllocationSize,EndOfFile=s.EndOfFile,Links=s.NumberOfLinks,VolumeId=b.VolumeSerial.ToString("X8"),FileId=b.IndexHigh.ToString("X8")+b.IndexLow.ToString("X8"),Attributes=b.Attributes,FinalPath=path.ToString(),FileSystem=fs.ToString(),FileSystemFlags=flags,CompressionFormat=format,FileCompressionInfo=c};
 }
}
'@
}
function Get-S14CalibrationAcl([IO.FileStream]$Stream){
 $acl=[IO.FileSystemAclExtensions]::GetAccessControl($Stream)
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or $rules[0].IsInherited){throw 'calibration_private_file_acl'}
 return $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group)
}
function Get-S14CalibrationHash([IO.FileStream]$Stream){
 $Stream.Position=0;$hash=[Security.Cryptography.SHA256]::Create()
 try{$bytes=$hash.ComputeHash($Stream);return [Convert]::ToHexString($bytes)}finally{$hash.Dispose()}
}
function Assert-S14CalibrationWitness($Witness,[string]$ExpectedPath){
 # Attribute changes due to compression are expected. Sparse/EFS/reparse/dir/device
 # and offline/recall files are not admitted, even if a compression API might work.
 $excluded=0x10 -bor 0x40 -bor 0x200 -bor 0x400 -bor 0x1000 -bor 0x4000 -bor 0x40000 -bor 0x400000
 if($Witness.FileSystem -cne 'NTFS' -or !($Witness.FileSystemFlags -band 0x10) -or $Witness.Links -ne 1 -or $Witness.EndOfFile -ne 64MB -or ($Witness.Attributes -band $excluded) -ne 0 -or !$Witness.FinalPath.Equals($ExpectedPath,[StringComparison]::OrdinalIgnoreCase)){throw 'calibration_file_identity_or_ntfs'}
}
function Assert-S14CalibrationStable($Before,$After,[string]$HashBefore,[string]$HashAfter,[string]$AclBefore,[string]$AclAfter){
 if($Before.VolumeId -cne $After.VolumeId -or $Before.FileId -cne $After.FileId -or $Before.EndOfFile -ne $After.EndOfFile -or $Before.Links -ne $After.Links -or $Before.FinalPath -cne $After.FinalPath -or $Before.FileSystem -cne $After.FileSystem -or (($Before.Attributes -band (-bnot 0x800)) -ne ($After.Attributes -band (-bnot 0x800))) -or $HashBefore -cne $HashAfter -or $AclBefore -cne $AclAfter){throw 'calibration_bytes_identity_or_acl_changed'}
}
function Invoke-S14SyntheticStorageCalibration {
 [CmdletBinding()]
 param([Parameter(Mandatory)][string]$NewDirectory,[Parameter(Mandatory)][DateTime]$DeadlineUtc)
 # No arbitrary file argument and no generic compression function is exported.
 # This routine can only create its fixed benign synthetic file in a NEW directory.
 $workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..')
 $root=Join-Path $workspace '.local/sprint14'
 $directory=Get-OwnedCanonicalPath $NewDirectory
 if(!$directory.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $directory) -or [DateTime]::UtcNow -ge $DeadlineUtc){throw 'calibration_new_s14_directory_required'}
 Assert-OwnedPrivateDirectory (Split-Path -Parent $directory)
 [void](New-OwnedPrivateDirectory $directory)
 $path=Join-Path $directory 'public-compression-calibration-64mib.txt'
 $expectedFinal=([PiResolvedPath]::Get($directory)).TrimEnd('\')+'\public-compression-calibration-64mib.txt'
 $stream=$null;$readback=$null;$steps=@();$complete=$false
 try{
  # CreateNew, no async/overlapped flag. This SINGLE handle stays exclusively open
  # throughout generation, all three IOCTLs and every before/after full-byte hash.
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow'))
  # Atomic explicit ACL creation avoids requiring a later path-open while this
  # handle is exclusive; FullControl requests READ_CONTROL/WRITE_DAC as well.
  $stream=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($path),[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,65536,[IO.FileOptions]::SequentialScan,$acl)
  if(!$stream.CanRead -or !$stream.CanWrite -or !$stream.CanSeek -or $stream.IsAsync){throw 'calibration_exclusive_readwrite_sync_required'}
  [void](Get-S14CalibrationAcl $stream)
  $line=[Text.UTF8Encoding]::new($false,$true).GetBytes("S14 public benign synthetic compression calibration; no customer data. 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ`n")
  $block=[byte[]]::new(65536)
  # Every byte is ASCII UTF8 (including a possible final partial line), so exact
  # 64MiB content has no split multibyte sequence and no hidden/sensitive inputs.
  for($i=0;$i -lt $block.Length;$i++){$block[$i]=$line[$i % $line.Length]}
  for($i=0;$i -lt 1024;$i++){
   if([DateTime]::UtcNow -ge $DeadlineUtc){throw 'calibration_write_deadline'}
   $stream.Write($block,0,$block.Length)
  }
  $stream.Flush($true)
  $baseline=[PiS13EvidenceStorageV1]::Inspect($stream);Assert-S14CalibrationWitness $baseline $expectedFinal
  # Inherited compressed directories are refused, not silently decompressed.
  if($baseline.CompressionFormat -ne 0 -or ($baseline.Attributes -band 0x800)){throw 'calibration_initial_uncompressed_required'}
  $hash=Get-S14CalibrationHash $stream;$baselineAcl=Get-S14CalibrationAcl $stream
  $previous=$baseline
  foreach($format in @(1,0,1)){
   if([DateTime]::UtcNow -ge $DeadlineUtc){throw 'calibration_ioctl_deadline'}
   $beforeHash=Get-S14CalibrationHash $stream;$beforeAcl=Get-S14CalibrationAcl $stream
   $before=[PiS13EvidenceStorageV1]::Inspect($stream);Assert-S14CalibrationWitness $before $expectedFinal
   Assert-S14CalibrationStable $baseline $before $hash $beforeHash $baselineAcl $beforeAcl
   $operation=[PiS13EvidenceStorageV1]::Set($stream,[ushort]$format)
   # Preserve actual return/error before refusing. No false successful step on API failure.
   $step=@{step=($steps.Count+1);operation=$operation;before=$before;before_sha256=$beforeHash;before_acl_sddl=$beforeAcl;exclusive_same_handle=$true}
   $steps+=,$step
   Write-OwnedJson (Join-Path $directory ('step-'+$steps.Count+'-api.json')) $step
   if(!$operation.ApiReturnedTrue -or $operation.Win32Error -ne 0){throw 'calibration_ioctl_failed_retained'}
   $stream.Flush($true)
   $after=[PiS13EvidenceStorageV1]::Inspect($stream);Assert-S14CalibrationWitness $after $expectedFinal
   $afterHash=Get-S14CalibrationHash $stream;$afterAcl=Get-S14CalibrationAcl $stream
   Assert-S14CalibrationStable $baseline $after $hash $afterHash $baselineAcl $afterAcl
   if(($format -eq 0 -and ($after.CompressionFormat -ne 0 -or ($after.Attributes -band 0x800))) -or ($format -eq 1 -and ($after.CompressionFormat -ne 2 -or !($after.Attributes -band 0x800)))){throw 'calibration_actual_compression_format'}
   $step.after=$after;$step.after_sha256=$afterHash;$step.after_acl_sddl=$afterAcl
   Write-OwnedJson (Join-Path $directory ('step-'+$steps.Count+'-observed.json')) $step
   # Creation can reserve excess allocation beyond EOF. Decompression must fit
   # the original allocation and cover EOF; excess need not be recreated.
   if(($format -eq 1 -and $after.AllocationSize -ge $baseline.AllocationSize) -or ($format -eq 0 -and ($after.AllocationSize -lt $after.EndOfFile -or $after.AllocationSize -gt $baseline.AllocationSize -or $after.FileCompressionInfo.CompressedFileSize -ne $after.EndOfFile))){throw 'calibration_allocated_size_expectation'}
   Write-OwnedJson (Join-Path $directory ('step-'+$steps.Count+'-complete.json')) $step
   $previous=$after
  }
  # Release the exclusive writer only AFTER all three operations and comparisons.
  $stream.Dispose();$stream=$null
  $readback=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,65536,[IO.FileOptions]::SequentialScan)
  $final=[PiS13EvidenceStorageV1]::Inspect($readback);Assert-S14CalibrationWitness $final $expectedFinal
  $finalHash=Get-S14CalibrationHash $readback;$finalAcl=Get-S14CalibrationAcl $readback
  Assert-S14CalibrationStable $baseline $final $hash $finalHash $baselineAcl $finalAcl
  if($final.AllocationSize -ne $previous.AllocationSize -or $final.CompressionFormat -ne 2 -or $steps.Count -ne 3){throw 'calibration_closed_handle_readback'}
  $complete=$true
  return @{status='S14_SYNTHETIC_STORAGE_CALIBRATION_EVIDENCE_PENDING_QA_TD';path=$path;logical_bytes=67108864;sha256=$hash;baseline=$baseline;steps=$steps;read_only_reopen_full_readback=$final;readback_sha256=$finalHash;acl_sddl=$finalAcl;all_three_api_returns_true=$true;whole_bytes_preserved=$true;limits=@('New public synthetic file only','No SQL capture/PG/binaries/old-file compression authorized','No budget cap reinterpretation or aggregate storage acceptance','Actual owned host/native exit/fullstreams must be supplied by outer runner')}
 }finally{
  if($stream){$stream.Dispose()};if($readback){$readback.Dispose()}
  if(!$complete){Write-OwnedJson (Join-Path $directory 'calibration-failed.json') @{status='FAILED_RETAINED';completed_step_records=$steps.Count;no_retry=$true;original_file_retained=$true;no_bytes_or_capacity_success_claim=$true}}
 }
}
Export-ModuleMember -Function Invoke-S14SyntheticStorageCalibration

<#
READ-ONLY native witness augmentation: class8 FILE_COMPRESSION_INFO is captured
through the retained same file handle at EVERY existing Inspect call (baseline,
stepbefore/after, read-only reopen). Native CompressedFileSize/CompressionFormat/
CompressionUnitShift/ChunkShift/ClusterShift are retained alongside the ORIGINAL
class1 FILE_STANDARD_INFO AllocationSize/EndOfFile/NumberOfLinks. Compression must
reduce AllocationSize. Decompression must cover EOF within baseline allocation,
with uncompressed CompressedFileSize=EOF. Creation excess need not recur; the
failed exact-equality first run and independent read-only witness are retained.
Physical CompressedFileSize selection for any future dual-cap accounting requires
independent review; these extra observations grant no capacity/budget PASS.
Official field layout read:
https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_compression_info
long8+ushort2+sixbytes=16bytes native sequential structure (three reservedbytes).
No APIs/import/calibration have been executed as part of this source edit.
#>
