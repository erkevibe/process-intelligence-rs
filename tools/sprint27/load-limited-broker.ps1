# Frozen ownership/stop logic plus read-only counters and opt-in commit limits.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if('S22Process' -as [type]){throw 'fresh_measurement_host_required'}
if([IntPtr]::Size -ne 8){throw 'x64_measurement_host_required'}
Import-Module ./tools/sprint21/owned-runtime.psm1 -Force -DisableNameChecking
$taskRuntime=Join-Path $PWD 'tools/sprint22/BrokerRuntime.cs'
$taskBroker=Join-Path $PWD 'tools/sprint24/runtime/ops-broker02.psm1'
Assert-OwnedHash $taskRuntime 'AEE15C33307143CB905571E375D87DFEED4D00A1DF5126417C7FCA8B99DF86B9'
Assert-OwnedHash $taskBroker 'AC782B64989AACEA5B0AB486A8662B1D7C218FE51139FD5E8743107B10E6EC90'
Assert-OwnedHash (Join-Path $PWD 'tools/sprint20/measured-runtime.psm1') '6875F8CF9910D7DBD1EE379A3D9ECA63AEDF754C25D8CC7B7F6908A31A5F438A'
Assert-OwnedHash (Join-Path $PWD 'tools/sprint20/process-times.psm1') '14EA74DE4C93C5E7046581AD52DE87C8B305C32C5B3269A3461E1E437ED245B0'
function Replace-S27ExactlyOnce([string]$Value,[string]$Before,[string]$After){
 if(([regex]::Matches($Value,[regex]::Escape($Before))).Count -ne 1){throw 'frozen_instrumentation_anchor'}
 return $Value.Replace($Before,$After)
}
$taskCs=[IO.File]::ReadAllText($taskRuntime)
$taskCs=Replace-S27ExactlyOnce $taskCs ' public bool Resumed {get;private set;}' ' public IntPtr BorrowedCounterHandle {get{if(process==IntPtr.Zero)throw new Exception("closed_counter_handle");return process;}} public bool Resumed {get;private set;}'
$taskLimit=@'
 [DllImport("kernel32.dll",EntryPoint="QueryInformationJobObject",SetLastError=true)] static extern bool S27QueryJob(IntPtr job,int kind,IntPtr information,uint length,out uint returned);
 public ulong ProcessMemoryLimit {get;private set;}
 public void LimitProcessMemory(ulong bytes){lock(sync){
  if(IntPtr.Size!=8||bytes<67108864UL||bytes>2147483648UL||Stopped||handle==IntPtr.Zero)throw new Exception("process_memory_limit_scope");
  var value=new S22Native.Extended();value.Basic.Flags=0x2100;value.PM=new UIntPtr(bytes);
  int n=Marshal.SizeOf<S22Native.Extended>();if(n!=144)throw new Exception("process_memory_limit_abi");var pointer=Marshal.AllocHGlobal(n);
  try{Marshal.StructureToPtr(value,pointer,false);S22Native.Check(S22Native.SetInformationJobObject(handle,9,pointer,(uint)n),"set_process_memory_limit");
   uint returned;S22Native.Check(S27QueryJob(handle,9,pointer,(uint)n,out returned),"query_process_memory_limit");var actual=Marshal.PtrToStructure<S22Native.Extended>(pointer);
   if(returned!=(uint)n||(actual.Basic.Flags&0x2100)!=0x2100||actual.PM.ToUInt64()!=bytes)throw new Exception("process_memory_limit_not_confirmed");ProcessMemoryLimit=bytes;
  }finally{Marshal.FreeHGlobal(pointer);}
 }}
'@
$taskCs=Replace-S27ExactlyOnce $taskCs ' public void Assign(IntPtr process){' ($taskLimit+"`n public void Assign(IntPtr process){")
Add-Type -TypeDefinition $taskCs
$taskSource=[IO.File]::ReadAllText($taskBroker)
$taskSource=Replace-S27ExactlyOnce $taskSource 'Import-Module (Join-Path $PSScriptRoot ''ops-pg-protocol02.psm1'') -Force' 'Import-Module (Join-Path $PWD ''tools/sprint24/runtime/ops-pg-protocol02.psm1'') -Force'
$taskSource=Replace-S27ExactlyOnce $taskSource 'if (''S22Process'' -as [type]) { throw ''s22_type_already_loaded_use_fresh_host'' }' '# Frozen S22Process loaded with counters and optional commit limits.'
$taskSource=Replace-S27ExactlyOnce $taskSource 'Add-Type -Path (Join-Path $PWD ''tools/sprint22/BrokerRuntime.cs'')' "Import-Module (Join-Path `$PWD 'tools/sprint20/measured-runtime.psm1') -Force`nImport-Module (Join-Path `$PWD 'tools/sprint20/process-times.psm1') -Force"
$taskInsert=@'
 $memory=Get-S20MeasuredProcessMemory $p.BorrowedCounterHandle
 if($memory.peak_working_set_bytes -le 0 -or $memory.peak_private_commit_bytes -le 0){throw 'lifetime_counter_unavailable'}
 $memory.scope='Native lifetime peaks from retained handle after actual exit. Working set includes shared pages; process commit limit is distinct.'
 $r.lifetime_memory_after_exit=$memory
 $r.lifetime_times_after_exit=Get-S20ProcessTimes $p.BorrowedCounterHandle $true
 if($r.lifetime_times_after_exit.creation_filetime_100ns -ne $p.CreationFileTime -or $r.lifetime_times_after_exit.exit_filetime_100ns -le $p.CreationFileTime){throw 'lifetime_counter_identity'}
 Write-OwnedJson ($p.Base+'.process.json') $r
'@
$taskSource=Replace-S27ExactlyOnce $taskSource ' Write-OwnedJson ($p.Base+''.process.json'') $r' $taskInsert
$taskSource=Replace-S27ExactlyOnce $taskSource '$job=[S22Job]::new($label);$State.jobs.Add($job);$State.stop.Add($job)' '$job=[S22Job]::new($label);$State.jobs.Add($job);$State.stop.Add($job);if($Command.ContainsKey(''process_memory_limit_bytes'')){$job.LimitProcessMemory([ulong]$Command.process_memory_limit_bytes)}'
$taskSource=Replace-S27ExactlyOnce $taskSource ' Write-OwnedJson ($base+''.start.json'') $start' ' if($job.ProcessMemoryLimit -gt 0){$start.process_memory_limit_bytes=$job.ProcessMemoryLimit};Write-OwnedJson ($base+''.start.json'') $start'
$taskModule=New-Module -Name S27LimitedBroker -ScriptBlock ([ScriptBlock]::Create($taskSource))
Import-Module $taskModule -Global -Force -DisableNameChecking
