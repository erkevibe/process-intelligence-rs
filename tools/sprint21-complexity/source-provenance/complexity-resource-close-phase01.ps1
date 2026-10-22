param([Parameter(Mandatory)][string]$Output)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PWD 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PWD 'tools/sprint15/evidence-storage.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PWD 'tools/sprint21-capacity/continuation-resource-guard.psm1') -Force
if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]'2026-10-22T22:46:12Z'){throw 'freeze'}
Assert-OwnedPrivateDirectory $Output
$start=[DateTimeOffset]::UtcNow
$sample=Get-S20ResourceSnapshot (Join-Path $PWD '.local/sprint21') (Join-Path $PWD '.local/sprint21/root/target')
$free=(Get-PSDrive C).Free
if($sample.root_logical_bytes -gt (8GB-512MB) -or $sample.root_allocation_bytes -gt (8GB-512MB) -or $sample.logical_bytes -gt (12GB-512MB) -or $sample.allocation_bytes -gt (12GB-512MB) -or $free -lt 8GB){throw 'capacity_bounds'}
Write-OwnedJson (Join-Path $Output 'resource-proof.json') @{status='FRESH_BOUNDED_RESOURCE_AFTER_VERIFIED_FILE_COUNT_REDUCTION';utc=[DateTimeOffset]::UtcNow.ToString('o');elapsed_ms=([DateTimeOffset]::UtcNow-$start).TotalMilliseconds;sample=$sample;free_bytes=$free;scan_seconds_cap=25;entries_cap=200000;headroom_bytes=512MB;original_complexity_owner_exit=1;original_reason='resource_sample_timeout during CMP90K; original three child completions UNKNOWN';prior_attempt_not_reclassified=$true;no_measurement_repeated=$true}