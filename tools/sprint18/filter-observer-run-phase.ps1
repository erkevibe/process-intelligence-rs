param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output_directory
Assert-OwnedHash $c.observer_executable $c.observer_sha256
Assert-OwnedHash $c.corpus_path $c.corpus_sha256
$corpus=Get-Content $c.corpus_path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($corpus.cases.Count -ne 8){throw 'frozen_eight_cases_required'}
$rows=@()
foreach($case in $corpus.cases){
 if($case.id -cnotmatch '^[a-z][a-z0-9-]{0,39}$' -or $case.file -cne ($case.id+'.json')){throw 'frozen_case_path'}
 $fixture=Join-Path (Split-Path $c.corpus_path) $case.file
 Assert-OwnedHash $fixture $case.sha256
 $label='filter-'+$case.id
 $native=Invoke-OwnedPhaseCommand $c.observer_executable $c.observer_sha256 @('--trusted-corpus',$fixture) $c.source_directory $c.output_directory $label @{} 30 1MB
 $observation=Join-Path $c.output_directory ($label+'.stdout')
 $value=Get-Content $observation -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($value.id -cne $case.id -or $value.input_sha256 -cne $case.sha256 -or $value.status -cne 'ACTUAL_RUST_CASE_ACTIVITY_FILTER_OBSERVED'){throw 'actual_rust_observation_identity'}
 $rows+=@{id=$case.id;input_sha256=$case.sha256;observation_path=$observation;observation_sha256=Get-OwnedHash $observation;native_record=Join-Path $c.output_directory ($label+'.process.json');native_record_sha256=Get-OwnedHash (Join-Path $c.output_directory ($label+'.process.json'));native_exit=$native.native_exit}
}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output_directory 'rust-results.json') @{schema_version=1;status='ACTUAL_RUST_FILTER_CORPUS_OBSERVED';source_commit=$c.source_commit;observer_sha256=$c.observer_sha256;corpus_sha256=$c.corpus_sha256;case_count=$rows.Count;cases=$rows;json_numeric_bytes_reencoded=$false;scope='Actual native diagnostic calls to production Rust filters API, independent comparison still required'}
