param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-phase-support.psm1') -Force -DisableNameChecking
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output
[void](Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha @('test','--offline','--locked','--manifest-path',(Join-Path $c.workspace 'Cargo.toml'),'--target-dir',$c.target,'--jobs','2','--doc','jobs::JobReservation','--','--test-threads=1') $c.workspace $c.output 'reservation-docs' @{RAYON_NUM_THREADS='1'} 180 4MB)
$out=[IO.File]::ReadAllText((Join-Path $c.output 'reservation-docs.stdout'))
if($out -notmatch 'test result: ok\. 2 passed; 0 failed;'){throw 'two_compile_fail_contracts_not_executed'}
Write-OwnedJson (Join-Path $c.output 'doc-proof.json') @{status='ACTUAL_TWO_RESERVATION_COMPILE_FAIL_CONTRACTS_PASS';native_exit=0;full_streams_eof=$true}