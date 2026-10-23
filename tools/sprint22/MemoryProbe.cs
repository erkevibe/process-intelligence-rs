using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;

// Read-only observer in the worker. Its file can be partial if that worker dies;
// native stdout/stderr ownership remains in the outer broker, not this observer.
public sealed class S22MemoryProbe : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct Memory {public uint Size,PageFaults;public UIntPtr PeakWorkingSet,WorkingSet,PeakPagedPool,PagedPool,PeakNonPagedPool,NonPagedPool,Commit,PeakCommit,PrivateCommit;}
 [StructLayout(LayoutKind.Sequential)] struct FileTime {public uint Low,High;public long Value{get{return ((long)High<<32)|Low;}}}
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out FileTime c,out FileTime e,out FileTime k,out FileTime u);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr process,uint flags,StringBuilder image,ref uint length);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("psapi.dll",SetLastError=true)] static extern bool GetProcessMemoryInfo(IntPtr process,ref Memory memory,uint size);
 readonly ManualResetEventSlim stop=new ManualResetEventSlim(); readonly Thread thread; readonly FileStream file; readonly IntPtr process; readonly uint pid; readonly long creation;
 volatile string stage="startup"; public volatile bool Fault,Completed; public int Count; public long Bytes; public string FaultCode; bool disposed;
 public S22MemoryProbe(uint expectedPid,long expectedCreation,string expectedImage,string output){
  if(IntPtr.Size!=8||Marshal.SizeOf<Memory>()!=80)throw new Exception("memory_abi");pid=expectedPid;creation=expectedCreation;
  process=OpenProcess(0x100410,false,pid);if(process==IntPtr.Zero)throw new Exception("memory_open_owned_identity");
  try{FileTime c,e,k,u;if(!GetProcessTimes(process,out c,out e,out k,out u)||c.Value!=creation)throw new Exception("memory_native_creation_mismatch");var image=new StringBuilder(32768);uint n=(uint)image.Capacity;if(!QueryFullProcessImageNameW(process,0,image,ref n)||!Path.GetFullPath(image.ToString()).Equals(Path.GetFullPath(expectedImage),StringComparison.OrdinalIgnoreCase))throw new Exception("memory_native_image_mismatch");
   file=new FileStream(output,FileMode.CreateNew,FileAccess.Write,FileShare.Read);Write("{\"kind\":\"header\",\"pid\":"+pid+",\"creation_filetime\":"+creation+",\"image_verified\":true,\"interval_ms_intended\":50,\"max_samples\":5000}");thread=new Thread(Sample);thread.IsBackground=true;thread.Start();
  }catch{file?.Dispose();CloseHandle(process);throw;}
 }
 void Write(string text){byte[] b=Encoding.UTF8.GetBytes(text+"\n");if(Bytes+b.Length>4*1024*1024)throw new Exception("memory_file_bound");file.Write(b,0,b.Length);file.Flush();Bytes+=b.Length;}
 void Point(){if(Count>=5000)throw new Exception("memory_sample_bound");if(WaitForSingleObject(process,0)!=0x102)throw new Exception("memory_target_exited_before_final_snapshot");var m=new Memory();m.Size=80;if(!GetProcessMemoryInfo(process,ref m,80))throw new Exception("memory_native_sample");Count++;Write("{\"kind\":\"sample\",\"number\":"+Count+",\"utc\":\""+DateTime.UtcNow.ToString("o",CultureInfo.InvariantCulture)+"\",\"stage\":\""+stage+"\",\"working_set\":"+m.WorkingSet.ToUInt64()+",\"private_commit\":"+m.PrivateCommit.ToUInt64()+",\"lifetime_peak_working_set\":"+m.PeakWorkingSet.ToUInt64()+",\"lifetime_peak_commit\":"+m.PeakCommit.ToUInt64()+",\"page_faults\":"+m.PageFaults+"}");}
 void Sample(){try{do{Point();}while(!stop.Wait(50));
   Point();if(WaitForSingleObject(process,0)!=0x102)throw new Exception("memory_final_target_not_alive");Write("{\"kind\":\"complete\",\"samples\":"+Count+",\"target_still_alive\":true}");file.Flush(true);Completed=true;
  }catch(Exception ex){Fault=true;FaultCode=ex.Message;}finally{file.Dispose();}
 }
 public void SetStage(string value){if(value!="startup"&&value!="warm_before"&&value!="http_client"&&value!="warm_after")throw new Exception("memory_stage");stage=value;}
 public void Dispose(){if(disposed)return;stop.Set();if(!thread.Join(5000))throw new Exception("memory_observer_stop_timeout");CloseHandle(process);disposed=true;}
}
// A direct managed delegate targets the broker's existing synchronized Stop;
// it never executes a PowerShell scriptblock on a background thread.
public sealed class S22AbsoluteStop : IDisposable {
 readonly ManualResetEventSlim cancel=new ManualResetEventSlim(); readonly Thread thread; public volatile bool Fired;
 public S22AbsoluteStop(long deadlineTicks,Action<string> callback){thread=new Thread(()=>{long remaining=deadlineTicks-System.Diagnostics.Stopwatch.GetTimestamp();int ms=(int)Math.Max(0,Math.Min(20000,Math.Ceiling(remaining*1000.0/System.Diagnostics.Stopwatch.Frequency)));if(!cancel.Wait(ms)){Fired=true;callback("pg_stop_absolute_deadline");}});thread.IsBackground=true;thread.Start();}
 public void Dispose(){cancel.Set();if(!thread.Join(1000))throw new Exception("absolute_observer_join");}
}
public sealed class S22ServiceWatch : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct FileTime {public uint Low,High;public long Value{get{return ((long)High<<32)|Low;}}}
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out FileTime c,out FileTime e,out FileTime k,out FileTime u);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr process,uint flags,StringBuilder image,ref uint length);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 readonly ManualResetEventSlim cancel=new ManualResetEventSlim();readonly Thread thread;readonly IntPtr process;
 public volatile bool ExpectedExit,Triggered;public readonly string AttachedUtc;
 public S22ServiceWatch(uint pid,long creation,string expectedImage,Action<string> callback){
  process=OpenProcess(0x101000,false,pid);if(process==IntPtr.Zero)throw new Exception("service_watch_open");
  try{FileTime c,e,k,u;var image=new StringBuilder(32768);uint n=(uint)image.Capacity;if(!GetProcessTimes(process,out c,out e,out k,out u)||c.Value!=creation||!QueryFullProcessImageNameW(process,0,image,ref n)||!Path.GetFullPath(image.ToString()).Equals(Path.GetFullPath(expectedImage),StringComparison.OrdinalIgnoreCase))throw new Exception("service_watch_native_identity");
   AttachedUtc=DateTime.UtcNow.ToString("o");thread=new Thread(()=>{while(!cancel.Wait(20)){uint state=WaitForSingleObject(process,0);if(state==0){if(!ExpectedExit){Triggered=true;callback("unexpected_service_exit");}return;}if(state!=0x102){Triggered=true;callback("service_watch_wait_fault");return;}}});thread.IsBackground=true;thread.Start();
  }catch{CloseHandle(process);throw;}
 }
 public void ExpectExit(){ExpectedExit=true;}
 public void Dispose(){cancel.Set();if(!thread.Join(1000))throw new Exception("service_watch_join");CloseHandle(process);}
}
