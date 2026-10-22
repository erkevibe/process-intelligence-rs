param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
$root=Join-Path $c.workspace '.local/sprint19/root'
if($c.python -cne (Join-Path $root 'pm4py-env/Scripts/python.exe') -or $c.wheelhouse -cne (Join-Path $root 'pm4py-wheels02')){throw 'reference_scope'}
if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc){throw 'reference_setup_deadline'}
$cache=New-OwnedPrivateDirectory (Join-Path $root 'target/reference-cache')
$envs=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1';MPLBACKEND='Agg';MPLCONFIGDIR=(Join-Path $cache 'mpl');XDG_CACHE_HOME=(Join-Path $cache 'xdg');OMP_NUM_THREADS='1';OPENBLAS_NUM_THREADS='1';MKL_NUM_THREADS='1';NUMEXPR_NUM_THREADS='1';NUMEXPR_MAX_THREADS='1';BLIS_NUM_THREADS='1';VECLIB_MAXIMUM_THREADS='1'}
foreach($dir in @($envs.MPLCONFIGDIR,$envs.XDG_CACHE_HOME)){[void][IO.Directory]::CreateDirectory($dir)}
$install=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B','-m','pip','--isolated','--disable-pip-version-check','--no-cache-dir','install','--no-index','--only-binary=:all:','--no-compile','--find-links',$c.wheelhouse,'--require-hashes','-r',$c.requirements_lock) $c.workspace $c.output 'offline-install' $envs 300 4MB
$check=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B','-m','pip','--isolated','--disable-pip-version-check','check') $c.workspace $c.output 'dependency-check' $envs 60 1MB
$wheel=Join-Path $c.wheelhouse 'pm4py-2.7.17-py3-none-any.whl'
Assert-OwnedHash $wheel '77FA0BBBE8284F0C94D577163213B5D4758BCF309A0266D34278A4476DF28686'
$site=Join-Path $root 'pm4py-env/Lib/site-packages'
$rows=[Collections.Generic.List[object]]::new()
$archive=[IO.Compression.ZipFile]::OpenRead($wheel)
try{foreach($entry in $archive.Entries){
 if($entry.FullName.EndsWith('/') -or $entry.FullName -ceq 'pm4py-2.7.17.dist-info/RECORD'){continue}
 if($entry.FullName -match '(^/|:|\\|(^|/)\.{1,2}(/|$))' -or $entry.Length -gt 16MB){throw 'wheel_member_bounds'}
 $path=Join-Path $site $entry.FullName
 Assert-OwnedNoReparse $path
 $s=$entry.Open();try{$expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s))}finally{$s.Dispose()}
 Assert-OwnedHash $path $expected
 $rows.Add(@{path=$entry.FullName;bytes=$entry.Length;sha256=$expected})
}}finally{$archive.Dispose()}
Write-OwnedJson (Join-Path $c.output 'pm4py-original-files.json') @{status='ALL_ORIGINAL_WHEEL_MEMBERS_EXCEPT_INSTALLER_REWRITTEN_RECORD_BYTE_IDENTICAL';wheel_sha256=Get-OwnedHash $wheel;files=$rows.ToArray();excluded=@('pm4py-2.7.17.dist-info/RECORD');all_source_files_preserved=$true}
$smoke=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B',$c.reference_adapter,'smoke','UNUSED',(Join-Path $c.output 'api-readiness.json')) $c.workspace $c.output 'api-smoke' $envs 120 2MB
foreach($row in $rows){Assert-OwnedHash (Join-Path $site $row.path) $row.sha256}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'reference-ready.json') @{status='OFFLINE_DEPENDENCIES_INSTALLED_ACTUAL_PM4PY_IMPORT_SOURCE_AND_CALLABLE_APIS_VERIFIED_NOT_MODEL_METRICS';python_sha256=$c.python_sha;lock_sha256=Get-OwnedHash $c.requirements_lock;source_files=$rows.Count;install_native_exit=$install.native_exit;dependency_check_native_exit=$check.native_exit;smoke_native_exit=$smoke.native_exit;thread_limit=1;cache_scope='new S19Root target/reference-cache only';no_model_or_metric_execution=$true}
