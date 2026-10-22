param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
Assert-OwnedPrivateDirectory $c.source_directory
$proof=Get-Content $c.build_proof -Raw|ConvertFrom-Json -AsHashtable
$observer=@($proof.observers|Where-Object name -CEQ 'bpmn_quality_cohort')
if($proof.status -cne 'ACTUAL_COHORT_PROVENANCE_TESTS_AND_THREE_DIAGNOSTIC_OBSERVERS_BUILT_NOT_ENGINE_RESULTS' -or $observer.Count -ne 1 -or $observer[0].sha256 -cne $c.observer_sha){throw 'actual_cohort_build_required'}
$originalFiles=Get-Content $c.reference_original_files -Raw|ConvertFrom-Json -AsHashtable
if($originalFiles.files.Count -ne 1375){throw 'original_reference_manifest'}
foreach($row in $originalFiles.files){Assert-OwnedHash (Join-Path $c.reference_site $row.path) $row.sha256}
$cache=Join-Path $c.target 'reference-cache'
Assert-OwnedPrivateDirectory $cache
$envs=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1';MPLBACKEND='Agg';MPLCONFIGDIR=(Join-Path $cache 'mpl');XDG_CACHE_HOME=(Join-Path $cache 'xdg');OMP_NUM_THREADS='1';OPENBLAS_NUM_THREADS='1';MKL_NUM_THREADS='1';NUMEXPR_NUM_THREADS='1';NUMEXPR_MAX_THREADS='1';BLIS_NUM_THREADS='1';VECLIB_MAXIMUM_THREADS='1'}
$projection=Join-Path $c.output 'projection'
$prepared=Join-Path $c.output 'prepared'
$project=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B',$c.project_adapter,'--cohort',$c.cohort_manifest,'--output',$projection) $c.workspace $c.output 'project-original-xml' $envs 60 4MB
$prepare=Invoke-OwnedPhaseCommand $c.observer $c.observer_sha @('prepare',$c.cohort_manifest,$projection,$prepared) $c.workspace $c.output 'rust-prepare' @{RAYON_NUM_THREADS='1'} 180 4MB
$files=@(Get-ChildItem -LiteralPath $prepared -Recurse -File -Force|Sort-Object FullName|ForEach-Object {@{path=[IO.Path]::GetRelativePath($prepared,$_.FullName);bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
# Rust creates this new child with inherited sole-SID permissions. Convert only
# that exact generated root to protected permissions, preserving the same rights.
if([IO.Path]::GetFullPath($prepared) -cne [IO.Path]::GetFullPath((Join-Path $c.output 'prepared'))){throw 'exact_new_generated_root'}
Assert-OwnedNoReparse $prepared
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($prepared))
$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'generated_root_not_single_owner'}
$beforeSddl=$acl.GetSecurityDescriptorSddlForm('All')
$acl.SetAccessRuleProtection($true,$true)
[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($prepared),$acl)
Assert-OwnedPrivateDirectory $prepared
foreach($row in $files){Assert-OwnedHash (Join-Path $prepared $row.path) $row.sha256}
Write-OwnedJson (Join-Path $c.output 'prepared-files-before-reference.json') @{files=$files;phase='miner_saved_before_reference_conversion_no_metrics';before_root_sddl=$beforeSddl;after_root_sddl=([IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($prepared))).GetSecurityDescriptorSddlForm('All');all_bytes_unchanged_by_acl_protection=$true}
$projectionFiles=@(Get-ChildItem -LiteralPath $projection -Recurse -File -Force|ForEach-Object {@{path=$_.FullName;sha256=Get-OwnedHash $_.FullName}})
$reference=Join-Path $c.output 'reference-conversion'
$convert=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B',$c.reference_adapter,'convert',$prepared,$reference) $c.workspace $c.output 'pm4py-convert-original' $envs 180 4MB
foreach($row in $files){Assert-OwnedHash (Join-Path $prepared $row.path) $row.sha256}
if(@(Get-ChildItem -LiteralPath $prepared -Recurse -File -Force).Count -ne $files.Count){throw 'prepared_file_set_changed'}
foreach($row in $projectionFiles){Assert-OwnedHash $row.path $row.sha256}
if(@(Get-ChildItem -LiteralPath $projection -Recurse -File -Force).Count -ne $projectionFiles.Count){throw 'projection_file_set_changed'}
foreach($row in $originalFiles.files){Assert-OwnedHash (Join-Path $c.reference_site $row.path) $row.sha256}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'prepare-proof.json') @{status='ACTUAL_ALL_EIGHT_HISTORICAL_MINER_OUTCOMES_PROJECTED_PREPARED_AND_ORIGINAL_XML_REFERENCE_CHECKED_NOT_METRICS';prepared=$prepared;reference_conversion=$reference;observer_sha256=$c.observer_sha;project_native_exit=$project.native_exit;prepare_native_exit=$prepare.native_exit;reference_native_exit=$convert.native_exit;all_prepared_projection_and_original_pm4py_bytes_unchanged=$true;not_new_miner_execution=$true;not_acceptance=$true;utc=[DateTimeOffset]::UtcNow.ToString('o')}
