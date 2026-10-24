param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output_directory
Assert-OwnedPrivateDirectory $c.source_directory
if($c.target -cne (Join-Path $c.workspace '.local/sprint18/root/target')){throw 'test_target_scope'}
Assert-OwnedHash $c.source_archive $c.source_archive_sha
$snapshot={@(Get-ChildItem $c.source_directory -File -Recurse -Force|Sort-Object FullName|ForEach-Object {@{path=[IO.Path]::GetRelativePath($c.source_directory,$_.FullName);bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})|ConvertTo-Json -Compress -Depth 4}
$before=& $snapshot
$manifest=Join-Path $c.source_directory 'Cargo.toml'
$checks=@(
 @{name='fmt';args=@('fmt','--manifest-path',$manifest,'--all','--','--check');seconds=120},
 @{name='tests';args=@('test','--offline','--locked','--all-targets','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2');seconds=1500},
 @{name='clippy';args=@('clippy','--offline','--locked','--all-targets','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2','--','-D','warnings');seconds=600}
)
$records=@()
foreach($check in $checks){
 $record=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha $check.args $c.source_directory $c.output_directory $check.name @{} $check.seconds 16MB
 $records+=@{name=$check.name;native_exit=$record.native_exit;stdout_complete=$record.stdout_complete;stderr_complete=$record.stderr_complete}
}
if((& $snapshot) -cne $before){throw 'frozen_test_source_changed'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output_directory 'test-proof.json') @{source_commit=$c.source_commit;source_archive_sha256=$c.source_archive_sha;commands=$records;full_source_unchanged=$true;postgres_live_tests_not_claimed=$true;scope='Exact frozen source local Windows full-target tests and warnings-as-errors. Database/browser acceptance is separate.'}
