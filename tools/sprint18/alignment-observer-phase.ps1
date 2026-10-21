param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output_directory
Assert-OwnedHash $c.observer_executable $c.observer_sha256
if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]'2026-10-21T21:25:42Z'){throw 'optional_completion_cutoff'}
if($c.operation -ceq 'mine'){
 if($c.mined_directory -cne (Join-Path $c.output_directory 'nets') -or (Test-Path $c.mined_directory)){throw 'new_mining_output'}
 $native=Invoke-OwnedPhaseCommand $c.observer_executable $c.observer_sha256 @('mine',$c.mined_directory) $c.source_directory $c.output_directory 'mine' @{RAYON_NUM_THREADS='1'} 120 8MB
 $files=@(Get-ChildItem $c.mined_directory -File|Sort-Object Name|ForEach-Object {@{name=$_.Name;bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
 $status='ACTUAL_ALPHA_NETS_SAVED_NOT_ALIGNED'
}elseif($c.operation -ceq 'align'){
 Assert-OwnedHash $c.saved_net_admission $c.saved_net_admission_sha256
 Assert-OwnedHash (Join-Path $c.mined_directory 'bundle.json') $c.saved_bundle_sha256
 if($c.measurement_file -cne (Join-Path $c.output_directory 'alignment-results.json') -or (Test-Path $c.measurement_file)){throw 'new_alignment_output'}
 $native=Invoke-OwnedPhaseCommand $c.observer_executable $c.observer_sha256 @('align',$c.mined_directory,$c.measurement_file) $c.source_directory $c.output_directory 'align' @{RAYON_NUM_THREADS='1'} 120 8MB
 $files=@(@{name='alignment-results.json';bytes=(Get-Item $c.measurement_file).Length;sha256=Get-OwnedHash $c.measurement_file})
 $status='ACTUAL_SEPARATE_PETRI_ALIGNMENT_OBSERVED_NOT_WHOLE_R4_ACCEPTED'
}else{throw 'finite_alignment_operation'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output_directory 'observer-result.json') @{status=$status;source_commit=$c.source_commit;observer_sha256=$c.observer_sha256;native=$native;files=$files;rayon_threads=1;scope='Actual bounded diagnostic operation only. Complete measurements/manual hypotheses and independent admission/acceptance remain separate; native0 does not imply all fitness values conclusive.'}
