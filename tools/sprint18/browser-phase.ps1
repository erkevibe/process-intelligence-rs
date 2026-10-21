param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-public-entry-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-guard.psm1') -Force
Import-Module (Join-Path $c.workspace 'tools/sprint15/evidence-storage.psm1') -Force -DisableNameChecking
if($c.app_port -ne 3106 -or $c.pg_port -ne 5486 -or $c.database -cne 'process_intelligence' -or $c.version -cne '0.7.5'){throw 'browser_scope'}
Assert-OwnedPrivateDirectory $c.output_directory
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content -LiteralPath (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json -DateKind String
if($m.source_commit -cne $c.source_commit -or $m.build_proof.executable_sha256 -cne $c.app_sha){throw 'candidate_identity'}
$deadline=[DateTimeOffset]'2026-10-21T22:55:42Z'
$started=[DateTimeOffset]::UtcNow
$nonce=[Guid]::NewGuid().ToString('N')
$service=$null
function Guard {
 if([DateTimeOffset]::UtcNow -ge $deadline -or ([DateTimeOffset]::UtcNow-$started).TotalMinutes -gt 28 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'browser_deadline_space'}
 $sample=Get-S18ResourceSnapshot (Join-Path $c.workspace '.local/sprint18') (Join-Path $c.workspace '.local/sprint18/root/target')
 if($sample.root_logical_bytes -gt (8GB-512MB) -or $sample.root_allocation_bytes -gt (8GB-512MB) -or $sample.logical_bytes -gt (12GB-512MB) -or $sample.allocation_bytes -gt (12GB-512MB)){throw 'browser_resource_headroom'}
 if($service -and ($service.Coordinator.Process.HasExited -or $service.Coordinator.OutCapture.LimitReached -or $service.Coordinator.ErrCapture.LimitReached -or $service.Coordinator.OutCapture.Pump.IsFaulted -or $service.Coordinator.ErrCapture.Pump.IsFaulted)){throw 'service_not_live'}
}
function WaitControl([string]$Kind){
 $file=Join-Path $c.output_directory ($Kind+'.json')
 $next=[DateTimeOffset]::UtcNow
 while(!(Test-Path -LiteralPath $file)){
  if([DateTimeOffset]::UtcNow -ge $next){Guard;$next=[DateTimeOffset]::UtcNow.AddSeconds(10)}
  Start-Sleep -Milliseconds 250
 }
 Assert-OwnedNoReparse $file
 if((Get-Item -LiteralPath $file).Length -gt 4096){throw 'control_bound'}
 $control=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($control.nonce -cne $nonce -or $control.kind -cne $Kind -or $control.author -cne 'Root'){throw 'control_identity'}
 if(!(Get-OwnedCanonicalPath $control.journal).StartsWith((Get-OwnedCanonicalPath $c.output_directory)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Get-Item -LiteralPath $control.journal).Length -gt 8MB){throw 'control_journal_scope'}
 Assert-OwnedNoReparse $control.journal
 Assert-OwnedHash $control.journal $control.journal_sha256
 return @{kind=$Kind;journal_sha256=$control.journal_sha256;native_manual_acceptance_not_inferred=$true}
}
try{
 Guard
 $service=Start-OwnedStockService $c $pkg 'cold-start'
 $first=Wait-OwnedStockService $service 120
 Write-OwnedJson (Join-Path $c.output_directory 'browser-ready.json') @{nonce=$nonce;url='http://127.0.0.1:3106';candidate_sha256=$c.app_sha;package=$pkg;processes=$first;status='READY_FOR_REAL_BROWSER_NOT_ACCEPTED'}
 $before=WaitControl 'before-restart'
 Stop-OwnedStockService $service 'fixture-finalization';$service=$null
 Guard
 $service=Start-OwnedStockService $c $pkg 'restart'
 $second=Wait-OwnedStockService $service 120
 Write-OwnedJson (Join-Path $c.output_directory 'browser-restarted.json') @{nonce=$nonce;processes=$second;status='READY_FOR_BROWSER_RESTART_VERIFICATION_NOT_ACCEPTED'}
 $after=WaitControl 'after-restart'
 Stop-OwnedStockService $service 'fixture-finalization';$service=$null
 Test-OwnedPackageTree $pkg $c.manifest_sha $true
 Write-OwnedJson (Join-Path $c.output_directory 'browser-result.json') @{status='PUBLIC_START_COLD_AND_RESTART_NATIVE_CLOSED';source_commit=$c.source_commit;app_sha256=$c.app_sha;before=$before;after=$after;browser_assertions='Actual named Root journals, independent acceptance separate';no_clean_app_exit_claim=$true}
}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}}
