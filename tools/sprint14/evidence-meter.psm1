# READ-ONLY S14 file inventory. Requires separately pinned owned-runtime and
# evidence-storage modules; imports/calls are the caller's prospective admission.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('PiS13AttributesHandle' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PiS13AttributesHandle {
 [StructLayout(LayoutKind.Sequential)] public struct Standard {
  public long AllocationSize; public long EndOfFile; public uint NumberOfLinks;
  [MarshalAs(UnmanagedType.U1)] public bool DeletePending;
  [MarshalAs(UnmanagedType.U1)] public bool Directory;
 }
 [StructLayout(LayoutKind.Sequential)] public struct Basic {
  public long CreationTime; public long LastAccessTime; public long LastWriteTime; public long ChangeTime; public uint Attributes;
 }
 [StructLayout(LayoutKind.Sequential)] public struct Identity {
  public uint Attributes,CreationLow,CreationHigh,AccessLow,AccessHigh,WriteLow,WriteHigh,VolumeSerial,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
 }
 [StructLayout(LayoutKind.Sequential)] public struct AttributeTag { public uint Attributes; public uint Tag; }
 public sealed class JunctionWitness {
  public string Path,FinalPath,Target,SubstituteName,PrintName,VolumeId,FileId;
  public uint Tag,Attributes,Links,ReparseBytes;
  public long AllocationSize,EndOfFile;
  public Basic Times;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder path,uint length,uint flags);
 [DllImport("kernel32.dll",SetLastError=true,EntryPoint="GetFileInformationByHandleEx")]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetStandard(SafeFileHandle h,int kind,out Standard data,uint bytes);
 [DllImport("kernel32.dll",SetLastError=true,EntryPoint="GetFileInformationByHandleEx")]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetBasic(SafeFileHandle h,int kind,out Basic data,uint bytes);
 [DllImport("kernel32.dll",SetLastError=true,EntryPoint="GetFileInformationByHandleEx")]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetTag(SafeFileHandle h,int kind,out AttributeTag data,uint bytes);
 [DllImport("kernel32.dll",SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Identity data);
 [DllImport("kernel32.dll",SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool DeviceIoControl(SafeFileHandle h,uint code,IntPtr input,uint inputBytes,byte[] output,uint outputBytes,out uint returned,IntPtr overlapped);
 static void Require(bool okay,string stage){if(!okay)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),stage);}
 public static JunctionWitness InspectFixtureJunction(string path,string expectedTarget) {
  // Read attributes, share7, OPEN_EXISTING, OPEN_REPARSE_POINT|BACKUP_SEMANTICS.
  // The link itself is opened. NO target traversal or mutation occurs here.
  using(var h=CreateFileW(path,128,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)){
   if(h.IsInvalid)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"fixture_junction_open");
   Standard s;Basic b;Identity id;AttributeTag tag;
   Require(GetStandard(h,1,out s,(uint)Marshal.SizeOf<Standard>()),"junction_FileStandardInfo");
   Require(GetBasic(h,0,out b,(uint)Marshal.SizeOf<Basic>()),"junction_FileBasicInfo");
   Require(GetTag(h,9,out tag,(uint)Marshal.SizeOf<AttributeTag>()),"junction_FileAttributeTagInfo");
   Require(GetFileInformationByHandle(h,out id),"junction_file_identity");
   var raw=new byte[16384];uint n;Require(DeviceIoControl(h,589992,IntPtr.Zero,0,raw,(uint)raw.Length,out n,IntPtr.Zero),"junction_FSCTL_GET_REPARSE_POINT");
   if(n<16 || n>raw.Length || BitConverter.ToUInt32(raw,0)!=0xA0000003 || tag.Tag!=0xA0000003 || BitConverter.ToUInt16(raw,4)+8!=n)throw new InvalidOperationException("fixture_junction_mountpoint_tag_shape");
   int so=BitConverter.ToUInt16(raw,8),sl=BitConverter.ToUInt16(raw,10),po=BitConverter.ToUInt16(raw,12),pl=BitConverter.ToUInt16(raw,14);
   if((so|sl|po|pl)%2!=0 || sl<2 || 16+so+sl>n || 16+po+pl>n)throw new InvalidOperationException("fixture_junction_name_bounds");
   var utf=new UnicodeEncoding(false,false,true);string sub=utf.GetString(raw,16+so,sl),print=utf.GetString(raw,16+po,pl);
   if(!sub.StartsWith(@"\??\",StringComparison.Ordinal) || sub.IndexOf('\0')>=0 || print.IndexOf('\0')>=0)throw new InvalidOperationException("fixture_junction_absolute_substitute");
   string rawTarget=sub.Substring(4),target=Path.GetFullPath(rawTarget);
   if(!rawTarget.Equals(expectedTarget,StringComparison.OrdinalIgnoreCase) || !target.Equals(expectedTarget,StringComparison.OrdinalIgnoreCase) || (print.Length>0 && !print.Equals(expectedTarget,StringComparison.OrdinalIgnoreCase)))throw new InvalidOperationException("fixture_junction_exact_internal_target");
   if(s.DeletePending || !s.Directory || s.NumberOfLinks<1 || s.NumberOfLinks!=id.Links || s.AllocationSize<0 || s.EndOfFile<0 || (b.Attributes&0x410)!=0x410 || b.Attributes!=tag.Attributes || b.Attributes!=id.Attributes)throw new InvalidOperationException("fixture_junction_native_metadata");
   var final=new StringBuilder(32768);uint finalLength=GetFinalPathNameByHandleW(h,final,(uint)final.Capacity,0);
   if(finalLength==0 || finalLength>=final.Capacity)throw new InvalidOperationException("fixture_junction_native_path");
   return new JunctionWitness{Path=path,FinalPath=final.ToString(),Target=target,SubstituteName=sub,PrintName=print,Tag=tag.Tag,Attributes=b.Attributes,Links=s.NumberOfLinks,AllocationSize=s.AllocationSize,EndOfFile=s.EndOfFile,VolumeId=id.VolumeSerial.ToString("X8"),FileId=id.IndexHigh.ToString("X8")+id.IndexLow.ToString("X8"),Times=b,ReparseBytes=n};
  }
 }
 public static SafeFileHandle Open(string path) {
  // FILE_READ_ATTRIBUTES only, SHARE_READ|WRITE|DELETE, OPEN_EXISTING,
  // OPEN_REPARSE_POINT. No content read/write, no FSCTL_SET_COMPRESSION here.
  var h=CreateFileW(path,128,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
  if(h.IsInvalid)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"meter_read_attributes_open");
  return h;
 }
}
'@
}
function Get-S14EvidenceInventory {
 [CmdletBinding()]
 param([Parameter(Mandatory)][DateTime]$DeadlineUtc,[int]$MaxFiles=160000)
 if($MaxFiles -lt 1 -or $MaxFiles -gt 160000){throw 'meter_file_bound'}
 if(-not ('PiS13EvidenceStorageV1' -as [type])){throw 'meter_pinned_calibration_type_required'}
 $root=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../../.local/sprint14')
 Assert-OwnedNoReparse $root
 # Never stop a process here. Active S14 PG or any compiler makes this quiet
 # measurement unavailable; other physical roots are not silently accounted.
 $running=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {
  ($_.Name -in @('cargo.exe','rustc.exe','rustdoc.exe','link.exe','clang.exe','gcc.exe')) -or
  ($_.Name -ceq 'postgres.exe' -and (!$_.ExecutablePath -or $_.ExecutablePath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)))
 })
 if($running.Count){throw 'meter_requires_closed_s14_pg_and_compilers'}
 $resolved=([PiResolvedPath]::Get($root)).TrimEnd('\')
 $start=[DateTime]::UtcNow;$end=$start.AddSeconds(240);if($DeadlineUtc -lt $end){$end=$DeadlineUtc}
 $files=[Collections.Generic.List[object]]::new();$directories=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $stack=[Collections.Generic.Stack[string]]::new();$stack.Push($root)
 $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $junctions=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
 $knownJunction=Get-OwnedCanonicalPath (Join-Path $root 'root/runner-regression01/reparse-link')
 $knownTarget=Get-OwnedCanonicalPath (Join-Path $root 'root/runner-regression01/reparse-target')
 $logical=0L;$allocated=0L;$pathBytes=0L
 $identities=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 function TimeGuard {if([DateTime]::UtcNow -ge $end){throw 'meter_inventory_deadline'}}
 function FixtureJunction([IO.FileSystemInfo]$Entry){
  TimeGuard
  if($Entry -isnot [IO.DirectoryInfo] -or !$Entry.FullName.Equals($knownJunction,[StringComparison]::OrdinalIgnoreCase)){throw 'meter_reparse_entry'}
  Assert-OwnedNoReparse $knownTarget
  if(![IO.Directory]::Exists($knownTarget)){throw 'meter_fixture_target_missing'}
  $a=[PiS13AttributesHandle]::InspectFixtureJunction($knownJunction,$knownTarget);$b=[PiS13AttributesHandle]::InspectFixtureJunction($knownJunction,$knownTarget)
  $expectedLink=$resolved+'\'+[IO.Path]::GetRelativePath($root,$knownJunction)
  $expectedTarget=$resolved+'\'+[IO.Path]::GetRelativePath($root,$knownTarget)
  if(!$a.FinalPath.Equals($expectedLink,[StringComparison]::OrdinalIgnoreCase) -or !([PiResolvedPath]::Get($knownTarget)).Equals($expectedTarget,[StringComparison]::OrdinalIgnoreCase)){throw 'meter_fixture_native_path_binding'}
  if(($a|ConvertTo-Json -Depth 5 -Compress) -cne ($b|ConvertTo-Json -Depth 5 -Compress)){throw 'meter_fixture_junction_metadata_race'}
  return $a
 }
 function InspectFile([string]$Path){
  TimeGuard
  $h=$null;$s=$null
  try{
   $h=[PiS13AttributesHandle]::Open($Path)
   # Adapter wraps the native attributes-only handle; NO stream Read/Write is
   # called. Calibrated Inspect uses native metadata queries on the SAME handle.
   $s=[IO.FileStream]::new($h,[IO.FileAccess]::Read,1,$false)
   $a=[PiS13EvidenceStorageV1]::Inspect($s);$b=[PiS13EvidenceStorageV1]::Inspect($s)
   $relative=[IO.Path]::GetRelativePath($root,$Path)
   $expected=$resolved+'\'+$relative
   if($a.Links -lt 1 -or $a.FileSystem -cne 'NTFS' -or ($a.Attributes -band 0x410) -or !$a.FinalPath.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'meter_file_reparse_or_volume'}
   if($a.VolumeId -cne $b.VolumeId -or $a.FileId -cne $b.FileId -or $a.Links -ne $b.Links -or $a.Attributes -ne $b.Attributes -or $a.EndOfFile -ne $b.EndOfFile -or $a.AllocationSize -ne $b.AllocationSize -or $a.FileCompressionInfo.CompressedFileSize -ne $b.FileCompressionInfo.CompressedFileSize -or $a.CompressionFormat -ne $b.CompressionFormat){throw 'meter_active_file_changed_during_inspect'}
   return @{path=$Path;relative_path=$relative;identity=($a.VolumeId+':'+$a.FileId);logical_bytes=$a.EndOfFile;allocated_bytes=$a.AllocationSize;witness=$a}
  }finally{if($s){$s.Dispose()}elseif($h){$h.Dispose()}}
 }
 while($stack.Count){
  TimeGuard;$dir=$stack.Pop();if(!$directories.Add($dir)){throw 'meter_duplicate_directory'}
  foreach($entry in [IO.DirectoryInfo]::new($dir).EnumerateFileSystemInfos()){
   TimeGuard
   if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){
    $j=FixtureJunction $entry;if($junctions.Count -ge 1 -or $junctions.ContainsKey($entry.FullName)){throw 'meter_fixture_junction_duplicate'}
    if([decimal]$logical+$j.EndOfFile -gt 32GB -or [decimal]$allocated+$j.AllocationSize -gt 32GB){throw 'meter_junction_size_overflow'}
    $junctions.Add($entry.FullName,$j);$logical+=$j.EndOfFile;$allocated+=$j.AllocationSize
    if($logical -gt 32GB){throw 'meter_logical_cap_including_junction'}
    continue
   }
   if($entry -is [IO.DirectoryInfo]){$stack.Push($entry.FullName);continue}
   if($files.Count -ge $MaxFiles -or !$paths.Add($entry.FullName)){throw 'meter_file_or_duplicate_bound'}
   $pathBytes+=[Text.Encoding]::UTF8.GetByteCount($entry.FullName);if($pathBytes -gt 64MB){throw 'meter_metadata_path_bound'}
   $r=InspectFile $entry.FullName
   if($identities.ContainsKey($r.identity)){$g=$identities[$r.identity];if($g.native_links -ne $r.witness.Links){throw 'meter_hardlink_count_race'};$g.observed_paths++}else{$identities.Add($r.identity,@{identity=$r.identity;native_links=$r.witness.Links;observed_paths=1})}
   if([decimal]$logical+$r.logical_bytes -gt 32GB -or [decimal]$allocated+$r.allocated_bytes -gt 32GB){throw 'meter_logical_cap_or_integer_overflow'}
   $logical+=$r.logical_bytes;$allocated+=$r.allocated_bytes;$files.Add($r)
  }
 }
 # Second complete namespace enumeration: never silently skip missing/temp/WAL/
 # failed/build/artifact/package files. Active churn causes explicit STOP.
 $second=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$secondDirs=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $stack.Push($root)
 $secondJunctions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 while($stack.Count){TimeGuard;$dir=$stack.Pop();if(!$secondDirs.Add($dir)){throw 'meter_second_directory_alias'};foreach($e in [IO.DirectoryInfo]::new($dir).EnumerateFileSystemInfos()){
  TimeGuard
  if($e.Attributes -band [IO.FileAttributes]::ReparsePoint){$j=FixtureJunction $e;if(!$secondJunctions.Add($e.FullName)-or !$junctions.ContainsKey($e.FullName)-or ($j|ConvertTo-Json -Depth 5 -Compress) -cne ($junctions[$e.FullName]|ConvertTo-Json -Depth 5 -Compress)){throw 'meter_second_junction_changed'};continue}
  if($e -is [IO.DirectoryInfo]){$stack.Push($e.FullName)}else{if(!$second.Add($e.FullName)-or !$paths.Contains($e.FullName)){throw 'meter_namespace_changed'}}
 }}
 if(!$paths.SetEquals($second)-or !$directories.SetEquals($secondDirs)){throw 'meter_namespace_changed'}
 if($secondJunctions.Count -ne $junctions.Count -or ($junctions.Count -and (!$directories.Contains($knownTarget)-or !$secondDirs.Contains($knownTarget)))){throw 'meter_junction_or_ordinary_target_not_fully_enumerated'}
 foreach($r in $files){$now=InspectFile $r.path;if($now.identity -cne $r.identity -or $now.witness.Links -ne $r.witness.Links -or $now.logical_bytes -ne $r.logical_bytes -or $now.allocated_bytes -ne $r.allocated_bytes -or $now.witness.Attributes -ne $r.witness.Attributes -or $now.witness.CompressionFormat -ne $r.witness.CompressionFormat -or $now.witness.FileCompressionInfo.CompressedFileSize -ne $r.witness.FileCompressionInfo.CompressedFileSize){throw 'meter_file_changed_between_passes'}}
 foreach($g in $identities.Values){if($g.observed_paths -gt $g.native_links){throw 'meter_hardlink_identity_inconsistency'}}
 $aliases=@($identities.Values|Where-Object {$_.native_links -gt 1}|Sort-Object identity)
 TimeGuard
 return @{scope='ALL_S14_REGULAR_FILE_ALLOCATIONS_PLUS_EXPLICIT_INTERNAL_FIXTURE_JUNCTION';root=$root;started_utc=$start.ToString('o');completed_utc=[DateTime]::UtcNow.ToString('o');file_count=$files.Count;logical_bytes=$logical;allocated_bytes=$allocated;allocation_metric='FileStandardInfo.AllocationSize';files=$files.ToArray();junctions=@($junctions.Values);junction_count=$junctions.Count;directory_allocation_scope='Regular FILE allocations plus explicit fixture junction native allocation; ordinarydirectory MFT/wholevolume cost NOT claimed';hardlinks='Every pathname charged FULL logical/allocation, aliases intentionally overcounted; NEVER deduplicated';hardlink_groups=$aliases;duplicate_identity_groups=@($aliases|Where-Object observed_paths -gt 1).Count;cross_boundary_link_groups=@($aliases|Where-Object {$_.observed_paths -lt $_.native_links}).Count;limits=@('Complete two-pass observed inventory; no atomic filesystem snapshot claim','Any inaccessible/missing/reparse/namespace or measured size race STOPs','All NEW S14 targets/artifacts/failed/PGWAL/temp/packages below S14 included','No ratio, disk-free delta or logical-as-physical fallback','Creating inventory receipts AFTER measurement needs separately reserved headroom','Public repository/source/Git deltas outside scope: explicit256MiB supplement reserve required by caller','Not whole Cdrive allocation; any additional managed private root needs explicit admission','All S14 PG/compiler closed; Node/proof writers must independently be quiet during passes')}
}
Export-ModuleMember -Function Get-S14EvidenceInventory

<#
SOURCE-ONLY narrow fixture-junction revision after honest meter01 reparse STOP.
Old executed5A771 module retained separately before edit. ONLY literal internal
root/runner-regression01/reparse-link -> sameparent/reparse-target is admitted.
Native read-only OPEN_REPARSE_POINT|BACKUP_SEMANTICS handle captures tagA0000003,
GET_REPARSE_POINT589992 rawmountpointtarget, FileStandardInfo AllocationSize/EOF/
links/directory, BasicInfo fourtimestamps/attrs, nativevolume/fileID and finalpath.
Exact literal+canonical internaltarget/no otherreparse required; actualtarget is
AssertOwnedNoReparse and MUST be fully visited as an ordinary directory BOTHpasses.
Junction itself NEVER traversed; contents counted via ordinarytarget only, no
external/unseen contents silently omitted. Nativejunction EOF/allocation included
in totals; complete<=1 junction metadata returned separately in junctions[].
Regular files remain .files for existing compression inventory serializer; summary
therefore binds explicitjunctionmetadata. ALL otherreparse STOP. No MFT/ordinary
directory/wholevolume cost claim. New native adapter UNEXECUTED pendingRootQA TD.
No link/target/file/PG mutation, process stopping, delete, rename or cap relaxation.
#>
