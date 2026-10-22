param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
Assert-OwnedHash $c.python $c.python_sha
Assert-OwnedHash $c.source_archive '91E85E9EE9B85D2391EAD7D635E3D9C7F5F44FD60A60E59B13E2403FA66505C4'
if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc){throw 'setup_deadline'}
$root=Join-Path $c.workspace '.local/sprint19/root'
if($c.python -cne (Join-Path $root 'pm4py-env/Scripts/python.exe') -or $c.temp -cne (Join-Path $root 'target/bootstrap-temp')){throw 'isolated_build_scope'}
$tools=@(Get-Content $c.buildtools_manifest -Raw|ConvertFrom-Json -AsHashtable -DateKind String).wheels
if($tools.Count -ne 3 -or @($tools|Where-Object package -NotIn @('setuptools','wheel','packaging')).Count){throw 'explicit_buildtools_only'}
foreach($tool in $tools){Assert-OwnedHash $tool.path $tool.sha256}
$installArgs=@('-I','-B','-m','pip','--isolated','--disable-pip-version-check','--no-cache-dir','install','--no-index','--no-deps','--no-compile')+@($tools.path)
$install=Invoke-OwnedPhaseCommand $c.python $c.python_sha $installArgs $c.workspace $c.output 'buildtools-install' @{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'} 120 2MB
$wheelDir=New-OwnedPrivateDirectory (Join-Path $root 'pydotplus-wheel01')
$build=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B','-m','pip','--isolated','--disable-pip-version-check','--no-cache-dir','wheel','--no-index','--no-deps','--no-build-isolation','--wheel-dir',$wheelDir,$c.source_archive) $c.workspace $c.output 'pydotplus-wheel' @{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'} 120 2MB
$built=@(Get-ChildItem $wheelDir -File)
if($built.Count -ne 1 -or $built[0].Name -cne 'pydotplus-2.0.2-py3-none-any.whl' -or $built[0].Length -gt 1MB){throw 'reviewed_source_wheel_result'}
$wheelhouse=New-OwnedPrivateDirectory (Join-Path $root 'pm4py-wheels02')
$download=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B','-m','pip','--isolated','--disable-pip-version-check','--no-cache-dir','download','--only-binary=:all:','--find-links',$wheelDir,'--index-url','https://pypi.org/simple','--dest',$wheelhouse,'pm4py==2.7.17') $c.workspace $c.output 'reference-wheel-download' @{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'} 300 4MB
$wheels=@(Get-ChildItem $wheelhouse -File|Sort-Object Name|ForEach-Object {@{name=$_.Name;bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
if($wheels.Count -gt 80 -or ($wheels|Measure-Object bytes -Sum).Sum -gt 512MB){throw 'wheelhouse_bound'}
Assert-OwnedHash (Join-Path $wheelhouse 'pm4py-2.7.17-py3-none-any.whl') '77FA0BBBE8284F0C94D577163213B5D4758BCF309A0266D34278A4476DF28686'
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'build-download-result.json') @{status='REVIEWED_PYDOTPLUS_BUILT_REFERENCE_WHEELS_DOWNLOADED_NOT_INSTALLED';source_sha256=Get-OwnedHash $c.source_archive;built_wheel_sha256=Get-OwnedHash $built[0].FullName;buildtools_native_exit=$install.native_exit;build_native_exit=$build.native_exit;download_native_exit=$download.native_exit;wheels=$wheels;pm4py_not_installed_or_imported=$true;no_metric_or_miner_execution=$true}
