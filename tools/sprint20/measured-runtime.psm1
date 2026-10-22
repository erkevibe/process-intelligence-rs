# OS counters for a fresh, owned per-trial Job. No engine or process is started here.
# Primary definitions: Microsoft JOBOBJECT_{EXTENDED_LIMIT,BASIC_ACCOUNTING}_INFORMATION
# and PROCESS_MEMORY_COUNTERS_EX. Commit bytes and working-set bytes are distinct.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('PiS20MeasuredJob' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public sealed class PiS20MeasuredJob : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct Basic { public long ProcessTime,JobTime;public uint Flags;public UIntPtr Min,Max;public uint Active;public UIntPtr Affinity;public uint Priority,Scheduling; }
 [StructLayout(LayoutKind.Sequential)] struct Io { public ulong R,W,O,RB,WB,OB; }
 [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic Basic;public Io Io;public UIntPtr ProcessLimit,JobLimit,PeakProcess,PeakJob; }
 [StructLayout(LayoutKind.Sequential)] struct Accounting { public long User,Kernel,PeriodUser,PeriodKernel;public uint PageFaults,TotalProcesses,ActiveProcesses,TerminatedProcesses; }
 [StructLayout(LayoutKind.Sequential)] struct Memory { public uint Size,PageFaults;public UIntPtr PeakWorkingSet,WorkingSet,PeakPagedPool,PagedPool,PeakNonPagedPool,NonPagedPool,Commit,PeakCommit,PrivateCommit; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes,string name);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,IntPtr information,uint length);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,IntPtr information,uint length,out uint returned);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool member);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
 [DllImport("psapi.dll",SetLastError=true)] static extern bool GetProcessMemoryInfo(IntPtr process,ref Memory counters,uint size);
 IntPtr handle;
 static Exception Failure(string code){return new InvalidOperationException(code+":"+Marshal.GetLastWin32Error());}
 public static int[] StructureSizes(){return new[]{Marshal.SizeOf<Basic>(),Marshal.SizeOf<Extended>(),Marshal.SizeOf<Accounting>(),Marshal.SizeOf<Memory>()};}
 public PiS20MeasuredJob(){
  if(IntPtr.Size!=8)throw new InvalidOperationException("measured_job_x64_required");
  var sizes=StructureSizes();if(sizes[0]!=64||sizes[1]!=144||sizes[2]!=48||sizes[3]!=80)throw new InvalidOperationException("measured_job_abi");
  handle=CreateJobObjectW(IntPtr.Zero,null);if(handle==IntPtr.Zero)throw Failure("measured_job_create");
  var limits=new Extended();limits.Basic.Flags=0x2000;int size=Marshal.SizeOf<Extended>();var pointer=Marshal.AllocHGlobal(size);
  try{Marshal.StructureToPtr(limits,pointer,false);if(!SetInformationJobObject(handle,9,pointer,(uint)size))throw Failure("measured_job_kill_on_close");}
  catch{Dispose();throw;}finally{Marshal.FreeHGlobal(pointer);}
 }
 public void Assign(IntPtr process){if(!AssignProcessToJobObject(handle,process))throw Failure("measured_job_assign");if(!Member(process))throw new InvalidOperationException("measured_job_membership");}
 public bool Member(IntPtr process){bool member;if(!IsProcessInJob(process,handle,out member))throw Failure("measured_job_member");return member;}
 T Query<T>(int kind) where T:struct {
  int size=Marshal.SizeOf<T>();var pointer=Marshal.AllocHGlobal(size);uint returned;
  try{if(!QueryInformationJobObject(handle,kind,pointer,(uint)size,out returned))throw Failure("measured_job_query");if(returned!=(uint)size)throw new InvalidOperationException("measured_job_returned_abi");return Marshal.PtrToStructure<T>(pointer);}
  finally{Marshal.FreeHGlobal(pointer);}
 }
 public ulong[] Snapshot(){
  var memory=Query<Extended>(9);var cpu=Query<Accounting>(1);
  if(cpu.User<0||cpu.Kernel<0)throw new InvalidOperationException("measured_job_negative_cpu");
  return new[]{memory.PeakJob.ToUInt64(),memory.PeakProcess.ToUInt64(),(ulong)cpu.User,(ulong)cpu.Kernel,(ulong)cpu.TotalProcesses,(ulong)cpu.ActiveProcesses,(ulong)cpu.TerminatedProcesses,(ulong)cpu.PageFaults};
 }
 public static ulong[] ProcessMemory(IntPtr process){
  var memory=new Memory();memory.Size=(uint)Marshal.SizeOf<Memory>();
  if(!GetProcessMemoryInfo(process,ref memory,memory.Size))throw Failure("measured_process_memory");
  return new[]{memory.PeakWorkingSet.ToUInt64(),memory.WorkingSet.ToUInt64(),memory.PeakCommit.ToUInt64(),memory.PrivateCommit.ToUInt64(),(ulong)memory.PageFaults};
 }
 public void Stop(){if(handle!=IntPtr.Zero&&!TerminateJobObject(handle,1))throw Failure("measured_job_stop");}
 public void Dispose(){if(handle!=IntPtr.Zero){var old=handle;handle=IntPtr.Zero;if(!CloseHandle(old))throw Failure("measured_job_close");}}
}
'@
}
function Get-S20MeasuredJobSnapshot([PiS20MeasuredJob]$Job){
 $values=$Job.Snapshot()
 return @{peak_job_commit_bytes=$values[0];peak_single_process_commit_bytes=$values[1];user_cpu_100ns=$values[2];kernel_cpu_100ns=$values[3];total_processes=$values[4];active_processes=$values[5];limit_terminated_processes=$values[6];page_faults=$values[7];scope='Fresh per-trial Job from assignment; includes assigned process and descendants; does not include pre-assignment startup. Commit is not physical working set.'}
}
function Get-S20MeasuredProcessMemory([IntPtr]$Handle){
 $values=[PiS20MeasuredJob]::ProcessMemory($Handle)
 return @{peak_working_set_bytes=$values[0];current_working_set_bytes=$values[1];peak_private_commit_bytes=$values[2];current_private_commit_bytes=$values[3];page_faults=$values[4];scope='OS process counters since process creation, observed at caller snapshot; a terminal pre-exit snapshot excludes subsequent teardown. Working set may include shared pages; commit is not working set.'}
}
Export-ModuleMember -Function Get-S20MeasuredJobSnapshot,Get-S20MeasuredProcessMemory
