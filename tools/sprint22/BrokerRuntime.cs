using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

// Versioned separately: importing an older test module cannot substitute its types.
public static class S22Native {
 [StructLayout(LayoutKind.Sequential)] public struct Security { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup { public int cb; public string reserved,desktop,title; public int x,y,xSize,ySize,xChars,yChars,fill,flags; public short show,reserved2; public IntPtr reservedPtr,input,output,error; }
 [StructLayout(LayoutKind.Sequential)] public struct StartupEx { public Startup Start; public IntPtr Attributes; }
 [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr Process,Thread; public uint Pid,Tid; }
 [StructLayout(LayoutKind.Sequential)] public struct Times { public uint Low,High; public long Value { get { return ((long)High<<32)|Low; } } }
 [StructLayout(LayoutKind.Sequential)] public struct Basic {public long ProcessTime,JobTime;public uint Flags;public UIntPtr Min,Max;public uint Active;public UIntPtr Affinity;public uint Priority,Scheduling;}
 [StructLayout(LayoutKind.Sequential)] public struct Io {public ulong R,W,O,RB,WB,OB;}
 [StructLayout(LayoutKind.Sequential)] public struct Extended {public Basic Basic;public Io Io;public UIntPtr PM,JM,PPM,PJM;}
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref Security security,uint size);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool SetHandleInformation(IntPtr h,uint mask,uint flags);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool InitializeProcThreadAttributeList(IntPtr p,int count,uint flags,ref IntPtr size);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool UpdateProcThreadAttribute(IntPtr p,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
 [DllImport("kernel32.dll")] public static extern void DeleteProcThreadAttributeList(IntPtr p);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateProcessW(string app,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string directory,ref StartupEx startup,out ProcessInfo info);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h,out uint exit);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetProcessTimes(IntPtr h,out Times creation,out Times exit,out Times kernel,out Times user);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool QueryFullProcessImageNameW(IntPtr h,uint flags,StringBuilder name,ref uint size);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateJobObjectW(IntPtr s,string n);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr j,int k,IntPtr p,uint l);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool member);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool TerminateJobObject(IntPtr j,uint exit);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool TerminateProcess(IntPtr process,uint exit);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
 public static void Check(bool ok,string code) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error(),code); }
 public static string Quote(string a) { if(a.IndexOf('\0')>=0)throw new ArgumentException("nul_argument");var b=new StringBuilder("\"");int n=0;foreach(char c in a){if(c=='\\'){n++;continue;}if(c=='\"'){b.Append('\\',n*2+1);b.Append(c);}else{b.Append('\\',n);b.Append(c);}n=0;}b.Append('\\',n*2);b.Append('"');return b.ToString(); }
}
public sealed class S22Job : IDisposable {
 IntPtr handle; readonly object sync=new object(); public bool Stopped {get;private set;}
 public readonly string Label; public string LastTerminateUtc {get;private set;} public int LastTerminateError {get;private set;} public bool LastTerminateSucceeded {get;private set;}
 public S22Job(string label="job"){Label=label;handle=S22Native.CreateJobObjectW(IntPtr.Zero,null);S22Native.Check(handle!=IntPtr.Zero,"job_create");var x=new S22Native.Extended();x.Basic.Flags=0x2000;int n=Marshal.SizeOf<S22Native.Extended>();IntPtr p=Marshal.AllocHGlobal(n);try{Marshal.StructureToPtr(x,p,false);S22Native.Check(S22Native.SetInformationJobObject(handle,9,p,(uint)n),"job_limits");}catch{Dispose();throw;}finally{Marshal.FreeHGlobal(p);}}
 public void Assign(IntPtr process){lock(sync){if(Stopped||handle==IntPtr.Zero)throw new Exception("job_closed");S22Native.Check(S22Native.AssignProcessToJobObject(handle,process),"job_assign");}}
 public bool Member(IntPtr process){lock(sync){bool m;S22Native.Check(S22Native.IsProcessInJob(process,handle,out m),"job_member");return m;}}
 public bool OwnerMember {get{return Member(S22Native.GetCurrentProcess());}}
 public void Stop(){lock(sync){if(handle!=IntPtr.Zero&&!Stopped){LastTerminateUtc=DateTime.UtcNow.ToString("o");LastTerminateSucceeded=S22Native.TerminateJobObject(handle,137);LastTerminateError=LastTerminateSucceeded?0:Marshal.GetLastWin32Error();if(!LastTerminateSucceeded)throw new Win32Exception(LastTerminateError,"job_stop");Stopped=true;}}}
 public void Dispose(){lock(sync){if(handle!=IntPtr.Zero){S22Native.CloseHandle(handle);handle=IntPtr.Zero;Stopped=true;}}}
}
public sealed class S22KillOperation { public string operation,utc,job_label; public uint pid; public bool success,already_stopped; public int native_error; }
public sealed class S22Stop : IDisposable {
 readonly object sync=new object(); readonly List<S22Job> jobs=new List<S22Job>();
 sealed class Tracked {public IntPtr Handle;public uint Pid;public S22Job Job;}
 readonly Dictionary<IntPtr,Tracked> processes=new Dictionary<IntPtr,Tracked>(); readonly List<S22KillOperation> killOperations=new List<S22KillOperation>();
 readonly ManualResetEventSlim deadlineCancel=new ManualResetEventSlim(),collectorCancel=new ManualResetEventSlim(); Thread deadlineThread,collectorThread;
 public volatile bool Latched; public string Reason {get;private set;} public string Utc {get;private set;} public string FinalizationDeadlineUtc {get;private set;} public string KillCompletedUtc {get;private set;} public bool KillFault {get;private set;}
 public void Add(S22Job j){lock(sync){if(Latched)throw new Exception("stop_latched_no_admission");jobs.Add(j);}}
 void Fallback(Tracked p){uint wait=S22Native.WaitForSingleObject(p.Handle,0);if(wait==0)return;bool ok=S22Native.TerminateProcess(p.Handle,137);int error=ok?0:Marshal.GetLastWin32Error();killOperations.Add(new S22KillOperation{operation="TerminateProcess",utc=DateTime.UtcNow.ToString("o"),pid=p.Pid,job_label=p.Job?.Label,success=ok,native_error=error});if(!ok)KillFault=true;}
 public void Track(IntPtr p,uint pid){lock(sync){var owned=new Tracked{Handle=p,Pid=pid};processes.Add(p,owned);if(Latched)Fallback(owned);}}
 public void AssignOwned(IntPtr p,S22Job j){lock(sync){ThrowIfStopped();j.Assign(p);if(!j.Member(p))throw new Exception("positive_job_membership");processes[p].Job=j;}}
 public void Untrack(IntPtr p){lock(sync){processes.Remove(p);}}
 public S22KillOperation[] KillOperations(){lock(sync){return killOperations.ToArray();}}
 public void ArmDeadline(int milliseconds){if(milliseconds<1||milliseconds>1800000||deadlineThread!=null)throw new Exception("session_deadline_bound");deadlineThread=new Thread(()=>{if(!deadlineCancel.Wait(milliseconds))Stop("session_or_absolute_deadline");});deadlineThread.IsBackground=true;deadlineThread.Start();}
 void ArmCollectorLimit(){FinalizationDeadlineUtc=DateTime.UtcNow.AddSeconds(25).ToString("o");collectorThread=new Thread(()=>{if(!collectorCancel.Wait(25000))S22Native.TerminateProcess(S22Native.GetCurrentProcess(),199);});collectorThread.IsBackground=true;collectorThread.Start();}
 public void ThrowIfStopped(){if(Latched)throw new Exception("stop_latched_no_admission");}
 public void Admit(S22Process p){lock(sync){ThrowIfStopped();p.ResumeOwned();}}
 public void Stop(string reason){lock(sync){if(Latched)return;Reason=reason;Utc=DateTime.UtcNow.ToString("o");Latched=true;try{ArmCollectorLimit();}catch{KillFault=true;}var failed=new HashSet<S22Job>();foreach(var j in jobs){bool already=j.Stopped;try{j.Stop();}catch{KillFault=true;failed.Add(j);j.Dispose();}killOperations.Add(new S22KillOperation{operation="TerminateJobObject",utc=j.LastTerminateUtc,job_label=j.Label,success=j.LastTerminateSucceeded,native_error=j.LastTerminateError,already_stopped=already});}foreach(var p in processes.Values){if(p.Job==null||failed.Contains(p.Job))Fallback(p);}KillCompletedUtc=DateTime.UtcNow.ToString("o");}}
 public void Dispose(){deadlineCancel.Set();collectorCancel.Set();}
}
public sealed class S22SpawnFailure : Exception {public readonly S22Process Owner; public S22SpawnFailure(S22Process owner,Exception cause):base("s22_spawn_admission_failure",cause){Owner=owner;}}
public sealed class S22Capture {
 readonly Stream input,output; readonly long limit; readonly Action stop;
 public readonly Task Pump; public volatile bool Eof,Truncated,Fault,Ready; public long Persisted,Observed;
 public S22Capture(Stream source,string path,long cap,Action onLimit){input=source;limit=cap;stop=onLimit;output=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read);Pump=Task.Factory.StartNew(()=>Copy(),CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);}
 void Copy(){Ready=true;try{byte[] b=new byte[16384];while(true){int n=input.Read(b,0,b.Length);if(n==0){Eof=true;break;}Interlocked.Add(ref Observed,n);int keep=(int)Math.Min(n,Math.Max(0,limit-Interlocked.Read(ref Persisted)));if(keep>0){output.Write(b,0,keep);output.Flush();Interlocked.Add(ref Persisted,keep);}if(keep<n&&!Truncated){Truncated=true;stop();}}}catch{Fault=true;stop();}finally{try{((FileStream)output).Flush(true);}catch{Fault=true;}output.Dispose();input.Dispose();}}
}
public sealed class S22Process : IDisposable {
 IntPtr process,thread; readonly S22Stop controller; readonly S22Job job;
 readonly CancellationTokenSource deadlineCancellation=new CancellationTokenSource();
 public readonly uint Pid; public readonly long CreationFileTime; public readonly string Image,CreationUtc; public readonly S22Capture Out,Err; public readonly string Base;
 public bool Resumed {get;private set;} public string ResumeUtc {get;private set;}
 public S22Process(string program,string[] arguments,string directory,Dictionary<string,string> environment,string prefix,long cap,S22Job ownedJob,S22Stop stop,bool controlFaultAfterIdentity=false){
  controller=stop;job=ownedJob;Base=prefix;controller.ThrowIfStopped();if(cap<1024||cap>64*1024*1024)throw new Exception("capture_cap");
  IntPtr stdinR=IntPtr.Zero,stdinW=IntPtr.Zero,stdoutR=IntPtr.Zero,stdoutW=IntPtr.Zero,stderrR=IntPtr.Zero,stderrW=IntPtr.Zero,attrs=IntPtr.Zero,list=IntPtr.Zero,env=IntPtr.Zero;bool attrsReady=false;
  try{
   var sec=new S22Native.Security{Length=Marshal.SizeOf<S22Native.Security>(),Inherit=true};
   S22Native.Check(S22Native.CreatePipe(out stdinR,out stdinW,ref sec,0),"stdin_pipe");S22Native.Check(S22Native.CreatePipe(out stdoutR,out stdoutW,ref sec,0),"stdout_pipe");S22Native.Check(S22Native.CreatePipe(out stderrR,out stderrW,ref sec,0),"stderr_pipe");
   foreach(var h in new[]{stdinW,stdoutR,stderrR})S22Native.Check(S22Native.SetHandleInformation(h,1,0),"noninherited_owner_pipe");
   IntPtr size=IntPtr.Zero;S22Native.InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);attrs=Marshal.AllocHGlobal(size);S22Native.Check(S22Native.InitializeProcThreadAttributeList(attrs,1,0,ref size),"attribute_init");attrsReady=true;
   list=Marshal.AllocHGlobal(IntPtr.Size*3);Marshal.WriteIntPtr(list,0,stdinR);Marshal.WriteIntPtr(list,IntPtr.Size,stdoutW);Marshal.WriteIntPtr(list,IntPtr.Size*2,stderrW);
   S22Native.Check(S22Native.UpdateProcThreadAttribute(attrs,0,new IntPtr(0x20002),list,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero),"explicit_stdio_list");
   var si=new S22Native.StartupEx();si.Start.cb=Marshal.SizeOf<S22Native.StartupEx>();si.Start.flags=0x100;si.Start.input=stdinR;si.Start.output=stdoutW;si.Start.error=stderrW;si.Attributes=attrs;
   var vars=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);foreach(System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()){string key=(string)e.Key;if(key.StartsWith("PI_",StringComparison.OrdinalIgnoreCase)||key.StartsWith("PG",StringComparison.OrdinalIgnoreCase)||key.Equals("PORT",StringComparison.OrdinalIgnoreCase)||key.Equals("RUST_LOG",StringComparison.OrdinalIgnoreCase))continue;vars[key]=(string)e.Value;}
   foreach(var e in environment){if(e.Key.IndexOfAny(new[]{'=', '\0'})>=0||e.Value.IndexOf('\0')>=0)throw new Exception("environment_shape");vars[e.Key]=e.Value;}
   var block=new StringBuilder();foreach(var e in vars)block.Append(e.Key).Append('=').Append(e.Value).Append('\0');block.Append('\0');env=Marshal.StringToHGlobalUni(block.ToString());
   var command=new StringBuilder(S22Native.Quote(program));foreach(var a in arguments)command.Append(' ').Append(S22Native.Quote(a));if(command.Length>30000)throw new Exception("command_bound");
   S22Native.ProcessInfo pi;S22Native.Check(S22Native.CreateProcessW(program,command,IntPtr.Zero,IntPtr.Zero,true,0x08080404,env,directory,ref si,out pi),"create_suspended");process=pi.Process;thread=pi.Thread;Pid=pi.Pid;controller.Track(process,Pid);
   S22Native.CloseHandle(stdinR);stdinR=IntPtr.Zero;S22Native.CloseHandle(stdinW);stdinW=IntPtr.Zero;S22Native.CloseHandle(stdoutW);stdoutW=IntPtr.Zero;S22Native.CloseHandle(stderrW);stderrW=IntPtr.Zero;
   controller.AssignOwned(process,job);
   S22Native.Times c,exitTime,k,u;S22Native.Check(S22Native.GetProcessTimes(process,out c,out exitTime,out k,out u),"native_creation");CreationFileTime=c.Value;CreationUtc=DateTime.FromFileTimeUtc(c.Value).ToString("o");var image=new StringBuilder(32768);uint length=(uint)image.Capacity;S22Native.Check(S22Native.QueryFullProcessImageNameW(process,0,image,ref length),"native_image");Image=image.ToString();if(!Path.GetFullPath(Image).Equals(Path.GetFullPath(program),StringComparison.OrdinalIgnoreCase))throw new Exception("native_image_mismatch");
   if(controlFaultAfterIdentity)throw new Exception("controlled_after_native_identity_before_pumps");
   Out=new S22Capture(new FileStream(new SafeFileHandle(stdoutR,true),FileAccess.Read,16384,false),prefix+".stdout",cap,()=>controller.Stop("output_or_capture_fault"));stdoutR=IntPtr.Zero;
   Err=new S22Capture(new FileStream(new SafeFileHandle(stderrR,true),FileAccess.Read,16384,false),prefix+".stderr",cap,()=>controller.Stop("output_or_capture_fault"));stderrR=IntPtr.Zero;
   if(!SpinWait.SpinUntil(()=>Out.Ready&&Err.Ready,5000))throw new Exception("capture_readiness_timeout");
  }catch(Exception ex){controller.Stop("spawn_admission_failure");if(process!=IntPtr.Zero){throw new S22SpawnFailure(this,ex);}Dispose();throw;}
  finally{foreach(var h in new[]{stdinR,stdinW,stdoutR,stdoutW,stderrR,stderrW})if(h!=IntPtr.Zero)S22Native.CloseHandle(h);if(attrsReady)S22Native.DeleteProcThreadAttributeList(attrs);if(attrs!=IntPtr.Zero)Marshal.FreeHGlobal(attrs);if(list!=IntPtr.Zero)Marshal.FreeHGlobal(list);if(env!=IntPtr.Zero)Marshal.FreeHGlobal(env);}
 }
 internal void ResumeOwned(){if(Resumed||process==IntPtr.Zero||!job.Member(process)||!Out.Ready||!Err.Ready||Exited)throw new Exception("resume_precondition");uint previous=S22Native.ResumeThread(thread);S22Native.Check(previous!=uint.MaxValue,"resume_thread");if(previous!=1){controller.Stop("unexpected_suspend_count");throw new Exception("unexpected_suspend_count");}Resumed=true;ResumeUtc=DateTime.UtcNow.ToString("o");S22Native.CloseHandle(thread);thread=IntPtr.Zero;}
 public bool Member {get{return job.Member(process);}}
 public bool Exited {get{if(process==IntPtr.Zero)throw new Exception("closed_handle");uint v=S22Native.WaitForSingleObject(process,0);if(v==0xFFFFFFFF)throw new Exception("native_wait_failed");return v==0;}}
 public uint ExitCode {get{if(!Exited)throw new Exception("not_terminated");uint code;S22Native.Check(S22Native.GetExitCodeProcess(process,out code),"native_exit");return code;}}
 public bool Wait(int milliseconds){if(milliseconds<0||milliseconds>30000)throw new Exception("wait_bound");return S22Native.WaitForSingleObject(process,(uint)milliseconds)==0;}
 public bool Drain(int milliseconds){if(!Exited||milliseconds<0||milliseconds>30000)throw new Exception("drain_precondition");if(Out==null||Err==null)return false;try{return Task.WaitAll(new[]{Out.Pump,Err.Pump},milliseconds);}catch{return false;}}
 public void StopOwnJob(){job.Stop();}
 public Task WatchDeadline(int milliseconds){if(milliseconds<100||milliseconds>1800000)throw new Exception("deadline_bound");return Task.Run(async()=>{try{await Task.Delay(milliseconds,deadlineCancellation.Token);if(!Exited)controller.Stop("child_timeout");}catch(OperationCanceledException){}catch{controller.Stop("deadline_watch_fault");}});}
 public Task WatchWorker(){return Task.Factory.StartNew(()=>{try{while(!Exited)Thread.Sleep(20);controller.Stop("worker_exit");}catch{controller.Stop("worker_watch_fault");}},CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);}
 public void Dispose(){deadlineCancellation.Cancel();if(process!=IntPtr.Zero){if(S22Native.WaitForSingleObject(process,0)!=0){controller.Stop("owner_dispose_active");S22Native.TerminateProcess(process,137);}controller.Untrack(process);S22Native.CloseHandle(process);process=IntPtr.Zero;}if(thread!=IntPtr.Zero){S22Native.CloseHandle(thread);thread=IntPtr.Zero;}}
}
