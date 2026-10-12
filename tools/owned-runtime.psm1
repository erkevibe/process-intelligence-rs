# Shared Windows test-runtime support. No database operations or automatic cleanup.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not ('PiOwnedJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
public sealed class PiOwnedJob : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct Basic {public long ProcessTime,JobTime;public uint Flags;public UIntPtr Min,Max;public uint Active;public UIntPtr Affinity;public uint Priority,Scheduling;}
 [StructLayout(LayoutKind.Sequential)] struct Io {public ulong R,W,O,RB,WB,OB;}
 [StructLayout(LayoutKind.Sequential)] struct Extended {public Basic Basic;public Io Io;public UIntPtr PM,JM,PPM,PJM;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr s,string n);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j,int k,IntPtr p,uint l);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool m);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr j,uint e);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 IntPtr job;
 public PiOwnedJob(){job=CreateJobObjectW(IntPtr.Zero,null);if(job==IntPtr.Zero)throw new Exception("job_create");var x=new Extended();x.Basic.Flags=0x2000;int n=Marshal.SizeOf<Extended>();var p=Marshal.AllocHGlobal(n);try{Marshal.StructureToPtr(x,p,false);if(!SetInformationJobObject(job,9,p,(uint)n))throw new Exception("job_limits");}catch{Dispose();throw;}finally{Marshal.FreeHGlobal(p);}}
 public void Assign(IntPtr p){if(!AssignProcessToJobObject(job,p))throw new Exception("job_assign");}
 public bool Member(IntPtr p){bool m;if(!IsProcessInJob(p,job,out m))throw new Exception("job_member");return m;}
 public void Stop(){if(job!=IntPtr.Zero&&!TerminateJobObject(job,1))throw new Exception("job_stop");}
 public void Dispose(){if(job!=IntPtr.Zero){CloseHandle(job);job=IntPtr.Zero;}}
}
public sealed class PiBoundedCapture {
 public volatile bool LimitReached,ReadComplete;
 public long Bytes;
 public readonly Task Pump;
 public PiBoundedCapture(Stream input,Stream output,long limit){Pump=Copy(input,output,limit);}
 async Task Copy(Stream input,Stream output,long limit){byte[] b=new byte[65536];while(true){int n=await input.ReadAsync(b,0,b.Length);if(n==0){ReadComplete=true;return;}int keep=(int)Math.Min((long)n,limit-Bytes);if(keep>0){await output.WriteAsync(b,0,keep);await output.FlushAsync();Bytes+=keep;}if(keep<n){LimitReached=true;return;}}}
}
public sealed class PiSpawnPipeIsolation : IDisposable {
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetHandleInformation(IntPtr h,out uint f);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr h,uint m,uint f);
 readonly IntPtr[] handles=new IntPtr[2];
 public readonly uint[] Before=new uint[2],Masked=new uint[2],Restored=new uint[2];
 public PiSpawnPipeIsolation(){try{for(int i=0;i<2;i++){var h=GetStdHandle(-11-i);uint f;if(h==IntPtr.Zero||h==new IntPtr(-1)||!GetHandleInformation(h,out f))throw new Exception("spawn_parent_stdio");handles[i]=h;Before[i]=f;if(!SetHandleInformation(h,1,0)||!GetHandleInformation(h,out f)||(f&1)!=0)throw new Exception("spawn_parent_mask");Masked[i]=f;}}catch{Dispose();throw;}}
 public void Dispose(){for(int i=0;i<2;i++){if(handles[i]==IntPtr.Zero)continue;uint f;if(!SetHandleInformation(handles[i],1,Before[i]&1)||!GetHandleInformation(handles[i],out f)||(f&1)!=(Before[i]&1))throw new Exception("spawn_parent_restore");Restored[i]=f;handles[i]=IntPtr.Zero;}}
}
public static class PiWindowsArguments {
 [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CommandLineToArgvW(string s,out int n);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
 public static string[] Parse(string s){int n;var p=CommandLineToArgvW(s,out n);if(p==IntPtr.Zero)throw new Exception("argv_parse");try{var a=new string[n];for(int i=0;i<n;i++)a[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(p,i*IntPtr.Size));return a;}finally{LocalFree(p);}}
}
public static class PiResolvedPath {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string n,uint a,uint s,IntPtr p,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(IntPtr h,System.Text.StringBuilder b,uint n,uint f);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static string Get(string path){var h=CreateFileW(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);if(h==new IntPtr(-1))throw new Exception("path_handle");try{var b=new System.Text.StringBuilder(32768);uint n=GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,0);if(n==0||n>=b.Capacity)throw new Exception("resolved_path");return b.ToString();}finally{CloseHandle(h);}}
}
'@
}
function Get-OwnedHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Assert-OwnedHash([string]$Path,[string]$Expected) {
    if ($Expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-OwnedHash $Path) -cne $Expected.ToUpperInvariant()) { throw 'input_sha_mismatch' }
}
function Get-OwnedCanonicalPath([string]$Path) { [IO.Path]::GetFullPath($Path) }
function Assert-OwnedNoReparse([string]$Path) {
    $canonical=Get-OwnedCanonicalPath $Path
    $workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '..')
    $within=$canonical.Equals($workspace,[StringComparison]::OrdinalIgnoreCase) -or $canonical.StartsWith($workspace+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
    $item = Get-Item -LiteralPath $canonical -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reparse_path' }
        if ($within -and $item.FullName.Equals($workspace,[StringComparison]::OrdinalIgnoreCase)) { break }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
    # Managed cloud ancestors above the workspace are allowed only through the
    # exact resolved workspace handle; no reparse below that boundary is allowed.
    if ($within) {
        $resolvedRoot=[PiResolvedPath]::Get($workspace).TrimEnd('\')
        $relative=[IO.Path]::GetRelativePath($workspace,$canonical)
        $expected=if ($relative -ceq '.') { $resolvedRoot } else { $resolvedRoot+'\'+$relative }
        if (-not ([PiResolvedPath]::Get($canonical)).Equals($expected,[StringComparison]::OrdinalIgnoreCase)) { throw 'resolved_workspace_path_mismatch' }
    }
}
function Assert-OwnedPrivateDirectory([string]$Path) {
    $p = Get-OwnedCanonicalPath $Path
    $workspace = Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '..')
    $prefix = Join-Path $workspace '.local/sprint11/'
    if (-not $p.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'owned_directory_bounds' }
    Assert-OwnedNoReparse $p
    $item = [IO.DirectoryInfo]::new($p)
    $acl = [IO.FileSystemAclExtensions]::GetAccessControl($item)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or -not $acl.AreAccessRulesProtected) { throw 'private_directory_owner' }
    $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) { throw 'private_directory_rules' }
}
function New-OwnedPrivateDirectory([string]$Path) {
    $p = Get-OwnedCanonicalPath $Path
    $workspace = Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '..')
    if (-not $p.StartsWith((Join-Path $workspace '.local/sprint11/'),[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $p)) { throw 'new_owned_directory_required' }
    Assert-OwnedNoReparse (Split-Path -Parent $p)
    [IO.Directory]::CreateDirectory($p) | Out-Null
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($p),$acl)
    Assert-OwnedPrivateDirectory $p
    return $p
}
function Write-OwnedJson([string]$Path,[object]$Value) {
    Assert-OwnedPrivateDirectory (Split-Path -Parent $Path)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20))
    if ($bytes.Length -gt 4MB) { throw 'proof_size_limit' }
    $s = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $s.Write($bytes,0,$bytes.Length); $s.Flush($true) } finally { $s.Dispose() }
}
function Get-OwnedByteSum([object[]]$Rows) {
    [long]$sum = 0
    foreach ($r in $Rows) {
        $n = if ($r -is [Collections.IDictionary]) { $r['bytes'] } else { $r.bytes }
        if ($null -eq $n -or $n -is [string] -or $n -is [bool] -or $n -isnot [ValueType] -or $n -lt 0 -or [decimal]$n -ne [decimal][long]$n -or [decimal]$n -gt ([decimal][long]::MaxValue - $sum)) { throw 'invalid_byte_sum' }
        $sum += [long]$n
    }
    return $sum
}
function Get-OwnedDatadirArgument([string]$CommandLine,[string]$Expected) {
    $args = [PiWindowsArguments]::Parse($CommandLine)
    $indexes = @(for ($i=1;$i -lt $args.Length;$i++) { if ($args[$i] -ceq '-D') { $i } })
    if (@($args | Where-Object { $_ -match '^(-D.+|--pgdata(?:=|$))' }).Count) { throw 'conflicting_pg_datadir_argument' }
    if ($indexes.Count -ne 1 -or $indexes[0]+1 -ge $args.Length) { throw 'pg_datadir_argument_count' }
    $actual = Get-OwnedCanonicalPath $args[$indexes[0]+1]
    if (-not $actual.Equals((Get-OwnedCanonicalPath $Expected),[StringComparison]::OrdinalIgnoreCase)) { throw 'pg_datadir_identity' }
    return $actual
}
function Start-OwnedCapturedProcess([string]$Program,[Parameter(Mandatory)][string]$ProgramSha256,[string[]]$Arguments,[string]$WorkingDirectory,[string]$OutputDirectory,[string]$Label,[long]$MaxOutputBytes,[hashtable]$Environment=@{},[bool]$RedirectInput=$false) {
    if ($Label -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or $MaxOutputBytes -lt 1024 -or $MaxOutputBytes -gt 1GB) { throw 'capture_limits' }
    Assert-OwnedPrivateDirectory $OutputDirectory
    Assert-OwnedNoReparse $Program; Assert-OwnedNoReparse $WorkingDirectory
    Assert-OwnedHash $Program $ProgramSha256
    $base = Join-Path $OutputDirectory $Label
    foreach ($suffix in @('.start.json','.process.json','.stdout','.stderr')) { if (Test-Path -LiteralPath ($base+$suffix)) { throw 'output_collision' } }
    $out = [IO.File]::Open(($base+'.stdout'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $err = [IO.File]::Open(($base+'.stderr'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Get-OwnedCanonicalPath $Program; $info.WorkingDirectory=Get-OwnedCanonicalPath $WorkingDirectory
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true; $info.RedirectStandardInput=$RedirectInput
    foreach ($key in @($info.Environment.Keys)) { if ($key -match '^(PI_|PG|PORT$|RUST_LOG$)') { [void]$info.Environment.Remove($key) } }
    foreach ($key in $Environment.Keys) { $info.Environment[$key]=[string]$Environment[$key] }
    foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
    $p=$null; $so=$null; $se=$null
    try {
        $started=[DateTime]::UtcNow.ToString('o'); Assert-OwnedHash $Program $ProgramSha256
        # The child's newly redirected pipes remain inheritable. Temporarily
        # mask only the parent's original standard handles so grandchildren
        # cannot retain an ancestor's otherwise unrelated capture pipe.
        $spawnIsolation=[PiSpawnPipeIsolation]::new()
        try { $p=[Diagnostics.Process]::Start($info) } finally { $spawnIsolation.Dispose() }
        $handle=$p.Handle
        $so=[PiBoundedCapture]::new($p.StandardOutput.BaseStream,$out,$MaxOutputBytes)
        $se=[PiBoundedCapture]::new($p.StandardError.BaseStream,$err,$MaxOutputBytes)
        $record=[ordered]@{pid=$p.Id;native_creation_utc=$p.StartTime.ToUniversalTime().ToString('o');started_utc=$started;program=$info.FileName;program_sha256=Get-OwnedHash $Program;native_exit=$null;stdout_complete=$false;stderr_complete=$false;environment_names=@($Environment.Keys|Sort-Object);parent_stdio_before=@($spawnIsolation.Before);parent_stdio_masked=@($spawnIsolation.Masked);parent_stdio_restored=@($spawnIsolation.Restored);scope_stdio='Parent capture inheritance disabled only during redirected child creation; original parent flags restored'}
        Write-OwnedJson ($base+'.start.json') $record
        return @{Process=$p;Handle=$handle;Stdout=$out;Stderr=$err;OutCapture=$so;ErrCapture=$se;Base=$base;Record=$record}
    } catch {
        if ($p -and -not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(10000) }
        # Streams are disposed only when no asynchronous capture can still write.
        if (-not $so -or $so.Pump.IsCompleted) { $out.Dispose() }
        if (-not $se -or $se.Pump.IsCompleted) { $err.Dispose() }
        if ($p) { $p.Dispose() }
        throw
    }
}
function Complete-OwnedCapturedProcess([hashtable]$Child,[int]$DrainSeconds=10) {
    if ($DrainSeconds -lt 1 -or $DrainSeconds -gt 30 -or -not $Child.Process.HasExited) { throw 'capture_completion_precondition' }
    $r=$Child.Record; $r.native_exit=$Child.Process.ExitCode; $r.completed_utc=[DateTime]::UtcNow.ToString('o')
    $complete=$false; $fault=$false
    try { $complete=[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Child.OutCapture.Pump,$Child.ErrCapture.Pump),$DrainSeconds*1000) } catch { $fault=$true; $complete=$Child.OutCapture.Pump.IsCompleted -and $Child.ErrCapture.Pump.IsCompleted }
    $r.stdout_complete=$complete -and -not $fault -and $Child.OutCapture.ReadComplete
    $r.stderr_complete=$complete -and -not $fault -and $Child.ErrCapture.ReadComplete
    $r.output_limit=$Child.OutCapture.LimitReached -or $Child.ErrCapture.LimitReached
    $r.stdout_bytes_persisted=$Child.OutCapture.Bytes; $r.stderr_bytes_persisted=$Child.ErrCapture.Bytes
    $r.drain_timeout=-not $complete; $r.capture_fault=$fault
    foreach ($pair in @(@($Child.Stdout,$Child.OutCapture),@($Child.Stderr,$Child.ErrCapture))) { if ($pair[1].Pump.IsCompleted) { $pair[0].Flush($true); $pair[0].Dispose() } }
    $r.stdout_sha256=if ($Child.OutCapture.Pump.IsCompleted) { Get-OwnedHash ($Child.Base+'.stdout') } else { $null }
    $r.stderr_sha256=if ($Child.ErrCapture.Pump.IsCompleted) { Get-OwnedHash ($Child.Base+'.stderr') } else { $null }
    Write-OwnedJson ($Child.Base+'.process.json') $r
    $Child.Process.Dispose()
    return $r
}
Export-ModuleMember -Function *-Owned*
