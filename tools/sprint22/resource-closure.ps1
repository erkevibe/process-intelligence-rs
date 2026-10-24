param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$Output)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]$PWD -cne [IO.Path]::GetFullPath($Workspace) -or [IO.Path]::GetFullPath($Output) -cne (Join-Path $Workspace '.local/sprint21/root/sprint22/resource-after-archive01')){throw 'resource_closure_scope'}
$guard=Join-Path $PSScriptRoot '../sprint21-capacity/continuation-resource-guard.psm1'
if((Get-FileHash $guard).Hash -cne '8EC87E1E91F07514C18B2698F5E77B35CD7A02AB8DCEEA4FF7268FB8609C3EC6'){throw 'unchanged_guard_required'}
Import-Module (Join-Path $PSScriptRoot '../sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module $guard -Force
$out=New-OwnedPrivateDirectory $Output
$clock=[Diagnostics.Stopwatch]::StartNew()
$snapshot=Get-S20ResourceSnapshot (Join-Path $Workspace '.local/sprint21') (Join-Path $Workspace '.local/sprint21/root/target')
$ms=$clock.ElapsedMilliseconds
if($snapshot.root_logical_bytes -gt (8GB-512MB) -or $snapshot.root_allocation_bytes -gt (8GB-512MB) -or $snapshot.logical_bytes -gt (12GB-512MB) -or $snapshot.allocation_bytes -gt (12GB-512MB) -or (Get-PSDrive C).Free -lt 8GB){throw 'resource_closure_threshold'}
Write-OwnedJson (Join-Path $out 'resource-proof.json') @{status='ACTUAL_UNCHANGED_RESOURCE_GUARD_AFTER_VERIFIED_ARCHIVE';utc=[DateTimeOffset]::UtcNow.ToString('o');elapsed_ms=$ms;snapshot=$snapshot;guard_sha256='8EC87E1E91F07514C18B2698F5E77B35CD7A02AB8DCEEA4FF7268FB8609C3EC6';thresholds_unchanged=$true;prior_adapter_phase_still='FAILED_GUARD';no_adapter_rerun=$true;no_product_or_postgres_started=$true}
