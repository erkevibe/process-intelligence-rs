param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc){throw 'bootstrap_deadline'}
$root=Join-Path $c.workspace '.local/sprint19/root'
if($c.cargo_home -cne (Join-Path $root 'cargo') -or $c.target -cne (Join-Path $root 'target') -or $c.temp -cne (Join-Path $root 'target/bootstrap-temp')){throw 'bootstrap_scope'}
[void](New-OwnedPrivateDirectory $c.target)
[void](New-OwnedPrivateDirectory $c.temp)
$cache=New-OwnedPrivateDirectory $c.cargo_home
Assert-OwnedNoReparse $c.cache_source
$oldFiles=@(Get-ChildItem $c.cache_source -File -Recurse -Force)
if($oldFiles.Count -gt 12000 -or ($oldFiles|Measure-Object Length -Sum).Sum -gt 256MB){throw 'cache_bound'}
$rows=[Collections.Generic.List[object]]::new()
foreach($file in $oldFiles){
 Assert-OwnedNoReparse $file.FullName
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc -or (Get-PSDrive C).Free -lt 8GB){throw 'copy_stop'}
 $rel=[IO.Path]::GetRelativePath($c.cache_source,$file.FullName)
 $dst=Join-Path $cache $rel
 [void][IO.Directory]::CreateDirectory((Split-Path $dst))
 $hash=Get-OwnedHash $file.FullName
 [IO.File]::Copy($file.FullName,$dst,$false)
 Assert-OwnedHash $dst $hash
 Assert-OwnedHash $file.FullName $hash
 $rows.Add(@{path=$rel;bytes=$file.Length;sha256=$hash})
}
Write-OwnedJson (Join-Path $c.output 'cargo-copy.json') @{files=$rows.ToArray();count=$rows.Count;old_source_read_only=$true;scope='S18 read-only cache to new private S19 cargo home'}
$envRoot=Join-Path $root 'pm4py-env'
if(Test-Path $envRoot){throw 'fresh_python_env'}
$venv=Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B','-m','venv','--copies',$envRoot) $c.workspace $c.output 'venv' @{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'} 120 2MB
Assert-OwnedNoReparse $envRoot
$python=Join-Path $envRoot 'Scripts/python.exe'
$wheelhouse=New-OwnedPrivateDirectory (Join-Path $root 'pm4py-wheels')
$download=Invoke-OwnedPhaseCommand $python (Get-OwnedHash $python) @('-I','-B','-m','pip','--isolated','--disable-pip-version-check','--no-cache-dir','download','--only-binary=:all:','--index-url','https://pypi.org/simple','--dest',$wheelhouse,'pm4py==2.7.17') $c.workspace $c.output 'wheel-download' @{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'} 300 4MB
$wheels=@(Get-ChildItem $wheelhouse -File|Sort-Object Name|ForEach-Object {@{name=$_.Name;bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
if($wheels.Count -gt 80 -or ($wheels|Measure-Object bytes -Sum).Sum -gt 512MB){throw 'wheelhouse_bound'}
Assert-OwnedHash (Join-Path $wheelhouse 'pm4py-2.7.17-py3-none-any.whl') '77FA0BBBE8284F0C94D577163213B5D4758BCF309A0266D34278A4476DF28686'
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'bootstrap-result.json') @{status='CACHES_COPIED_VENV_CREATED_WHEELS_DOWNLOADED_NOT_INSTALLED_OR_EVALUATED';python=$python;python_sha256=Get-OwnedHash $python;venv_native_exit=$venv.native_exit;download_native_exit=$download.native_exit;wheels=$wheels;reference_not_installed=$true;no_mining_or_metric_execution=$true}
