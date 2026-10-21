Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $workspace 'tools/sprint18/resource-guard.psm1') -Force
$target=Join-Path $workspace '.local/sprint18/root/target'
$missing=Join-Path $target ('missing-resource-probe-'+[Guid]::NewGuid().ToString('N'))
try{[void][IO.Directory]::GetFiles($missing);throw 'expected_missing_directory'}catch{
 if(!(Test-S18GoneTargetError $_.Exception $missing $target)){throw 'typed_target_disappearance_not_allowed'}
}
foreach($path in @(
 (Join-Path $workspace '.local/sprint18/root/frozen01/missing'),
 (Join-Path $workspace '.local/sprint18/root/cargo/missing'),
 (Join-Path $workspace '.local/sprint18/qa/missing'),
 ($target+'-sibling/missing')
)){
 if(Test-S18GoneTargetError ([IO.DirectoryNotFoundException]::new()) $path $target){throw 'non_target_disappearance_allowed'}
}
foreach($errorType in @([UnauthorizedAccessException],[IO.IOException],[ArgumentException])){
 if(Test-S18GoneTargetError ([Activator]::CreateInstance($errorType)) $missing $target){throw 'unrelated_error_allowed'}
}
if(Test-S18GoneTargetError ([IO.FileNotFoundException]::new()) $target $target){throw 'target_root_missing_allowed'}
Write-Output 'PASS: actual missing target descendant only; source/cache/QA/sibling/access/other errors refuse.'
