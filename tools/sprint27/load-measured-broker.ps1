# Test-only extension of the frozen broker: borrow its retained process handle
# for read-only lifetime counters after native exit. No launcher/stop change.
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
Add-Type -TypeDefinition $taskCs
$taskSource=[IO.File]::ReadAllText($taskBroker)
$taskSource=Replace-S27ExactlyOnce $taskSource 'Import-Module (Join-Path $PSScriptRoot ''ops-pg-protocol02.psm1'') -Force' 'Import-Module (Join-Path $PWD ''tools/sprint24/runtime/ops-pg-protocol02.psm1'') -Force'
$taskSource=Replace-S27ExactlyOnce $taskSource 'if (''S22Process'' -as [type]) { throw ''s22_type_already_loaded_use_fresh_host'' }' '# Frozen S22Process loaded above with one read-only borrowed accessor.'
$taskSource=Replace-S27ExactlyOnce $taskSource 'Add-Type -Path (Join-Path $PWD ''tools/sprint22/BrokerRuntime.cs'')' "Import-Module (Join-Path `$PWD 'tools/sprint20/measured-runtime.psm1') -Force`nImport-Module (Join-Path `$PWD 'tools/sprint20/process-times.psm1') -Force"
$taskInsert=@'
 $memory=Get-S20MeasuredProcessMemory $p.BorrowedCounterHandle
 if($memory.peak_working_set_bytes -le 0 -or $memory.peak_private_commit_bytes -le 0){throw 'lifetime_counter_unavailable'}
 $memory.scope='Native lifetime peaks from the same retained process handle after actual exit, including startup and teardown. Current post-exit usage is not an allocation peak. Working set may include shared pages; commit is distinct.'
 $r.lifetime_memory_after_exit=$memory
 $r.lifetime_times_after_exit=Get-S20ProcessTimes $p.BorrowedCounterHandle $true
 if($r.lifetime_times_after_exit.creation_filetime_100ns -ne $p.CreationFileTime -or $r.lifetime_times_after_exit.exit_filetime_100ns -le $p.CreationFileTime){throw 'lifetime_counter_identity'}
 Write-OwnedJson ($p.Base+'.process.json') $r
'@
$taskSource=Replace-S27ExactlyOnce $taskSource ' Write-OwnedJson ($p.Base+''.process.json'') $r' $taskInsert
$taskModule=New-Module -Name S27MeasuredBroker -ScriptBlock ([ScriptBlock]::Create($taskSource))
Import-Module $taskModule -Global -Force -DisableNameChecking
