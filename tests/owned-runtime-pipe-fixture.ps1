param([Parameter(Mandatory)][string]$NodeExe,[Parameter(Mandatory)][string]$NodeSha256)
$ErrorActionPreference='Stop'
if ((Get-FileHash -LiteralPath $NodeExe).Hash -cne $NodeSha256.ToUpperInvariant() -or $NodeExe.Contains('"')) { throw 'fixture_node_pin' }
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PiPipeFixture {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Start {public uint cb;public string reserved,desktop,title;public uint x,y,xs,ys,xc,yc,fill,flags;public ushort show,reserved2;public IntPtr reservedPtr,input,output,error;}
 [StructLayout(LayoutKind.Sequential)] struct Info {public IntPtr process,thread;public uint pid,tid;}
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool DuplicateHandle(IntPtr sp,IntPtr sh,IntPtr tp,out IntPtr th,uint a,bool inherit,uint options);
 [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetHandleInformation(IntPtr h,out uint f);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Start startup,out Info info);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static uint Spawn(string node){IntPtr output=IntPtr.Zero,error=IntPtr.Zero;Info pi=new Info();try{
   if(!DuplicateHandle(GetCurrentProcess(),GetStdHandle(-11),GetCurrentProcess(),out output,0,true,2)||!DuplicateHandle(GetCurrentProcess(),GetStdHandle(-12),GetCurrentProcess(),out error,0,true,2))throw new Exception("fixture_duplicate");
   uint inheritFlags;if(GetFileType(output)!=3||!GetHandleInformation(output,out inheritFlags)||(inheritFlags&1)==0)throw new Exception("fixture_inheritable_pipe_required");
   var s=new Start();s.cb=(uint)Marshal.SizeOf<Start>();s.flags=0x100;s.input=GetStdHandle(-10);s.output=output;s.error=error;
   const string code="process.stdout.write(JSON.stringify({holder:process.pid})+String.fromCharCode(10));setTimeout(()=>{},60000)";
   var command=new StringBuilder("\""+node+"\" -e \""+code+"\"");
   if(!CreateProcessW(node,command,IntPtr.Zero,IntPtr.Zero,true,0x08000000,IntPtr.Zero,null,ref s,out pi))throw new Exception("fixture_create");
   return pi.pid;
 }finally{if(output!=IntPtr.Zero)CloseHandle(output);if(error!=IntPtr.Zero)CloseHandle(error);if(pi.thread!=IntPtr.Zero)CloseHandle(pi.thread);if(pi.process!=IntPtr.Zero)CloseHandle(pi.process);}}
}
'@
$child=[PiPipeFixture]::Spawn([IO.Path]::GetFullPath($NodeExe))
[Console]::Out.WriteLine((@{parent=$PID;descendant=$child;inheritable_stdout_pipe_verified=$true}|ConvertTo-Json -Compress))
# Parent exits naturally; its inherited writer remains in the same owned Job.
