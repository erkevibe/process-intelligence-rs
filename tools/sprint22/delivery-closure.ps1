param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$Output)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Workspace=[IO.Path]::GetFullPath($Workspace)
if([string]$PWD -cne $Workspace -or [IO.Path]::GetFullPath($Output) -cne (Join-Path $Workspace '.local/sprint21/root/sprint22/delivery-resource01')){throw 'delivery_closure_scope'}
$guard=Join-Path $PSScriptRoot '../sprint21-capacity/continuation-resource-guard.psm1'
if((Get-FileHash -LiteralPath $guard).Hash -cne '8EC87E1E91F07514C18B2698F5E77B35CD7A02AB8DCEEA4FF7268FB8609C3EC6'){throw 'unchanged_guard_required'}
Import-Module (Join-Path $PSScriptRoot '../sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module $guard -Force
$out=New-OwnedPrivateDirectory $Output
$clock=[Diagnostics.Stopwatch]::StartNew()
$snapshot=Get-S20ResourceSnapshot (Join-Path $Workspace '.local/sprint21') (Join-Path $Workspace '.local/sprint21/root/target')
$scanMs=$clock.ElapsedMilliseconds
if($snapshot.root_logical_bytes -gt (8GB-512MB) -or $snapshot.root_allocation_bytes -gt (8GB-512MB) -or $snapshot.logical_bytes -gt (12GB-512MB) -or $snapshot.allocation_bytes -gt (12GB-512MB) -or (Get-PSDrive C).Free -lt 8GB){throw 'unchanged_resource_threshold'}
$images=@('process-intelligence-rs.exe','postgres.exe','pg_ctl.exe','psql.exe','pg_isready.exe','cargo.exe','rustc.exe')
$active=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -in $images -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Workspace+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)} | ForEach-Object {@{name=$_.Name;pid=$_.ProcessId}})
if($active.Count -ne 0){throw 'owned_workspace_native_workload_not_quiet'}
$ports=@()
foreach($port in @(3139,55449)){
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
    try{$listener.Start();$ports+=@{port=$port;bind_free=$true}}finally{$listener.Stop()}
}
if(Test-Path -LiteralPath (Join-Path $Workspace '.local/sprint21/root/pgdata11/postmaster.pid')){throw 'owned_pgdata11_still_has_pid'}
if($clock.Elapsed.TotalSeconds -gt 45){throw 'delivery_closure45s'}
Write-OwnedJson (Join-Path $out 'closure.json') @{status='ACTUAL_UNCHANGED_GUARD_AND_OWNED_NATIVE_QUIET_POINT';utc=[DateTimeOffset]::UtcNow.ToString('o');guard_sha256='8EC87E1E91F07514C18B2698F5E77B35CD7A02AB8DCEEA4FF7268FB8609C3EC6';scan_ms=$scanMs;snapshot=$snapshot;free_bytes=[long](Get-PSDrive C).Free;workspace_native_workloads=$active;ports=$ports;pgdata11_pid_absent=$true;thresholds_unchanged=$true;scope='Point-in-time owned workspace workload and resource check; no claim arbitrary unrelated processes or collector/host failures are covered';historical_unknowns=6;historical_unknowns_repaired=$false}
