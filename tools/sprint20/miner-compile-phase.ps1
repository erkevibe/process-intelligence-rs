param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'miner-support.psm1') -Force -DisableNameChecking
$classpath=Assert-S20MinerEnvironment $c
Assert-OwnedPrivateDirectory $c.output
if($c.java_sources.Count -ne 2){throw 'two_own_java_sources'}
foreach($source in $c.java_sources){Assert-OwnedHash $source.path $source.sha256}
$environment=New-S20JavaEnvironment $c.output
$classes=New-OwnedPrivateDirectory (Join-Path $c.output 'classes')
$argfile=Join-Path $c.output 'javac.args'
Write-S20JavaArgs $argfile (@('-proc:none','-encoding','UTF-8','-classpath',$classpath,'-d',$classes)+@($c.java_sources|ForEach-Object{$_.path}))
$compilerJvm=@(Get-S20JvmArgs $c.output|ForEach-Object{'-J'+$_})
$result=Invoke-OwnedPhaseCommand $c.javac $c.javac_sha ($compilerJvm+@('@'+$argfile)) (Join-Path $c.output 'cwd') $c.output 'javac' $environment 180 8MB
$files=@(Get-ChildItem -LiteralPath $classes -File -Recurse -Force|Sort-Object FullName|ForEach-Object{@{path=[IO.Path]::GetRelativePath($classes,$_.FullName);bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
if($files.Count -eq 0 -or @($files|Where-Object{$_.path -notlike '*.class'}).Count -ne 0){throw 'class_output_set'}
[void](Assert-S20MinerEnvironment $c)
Write-OwnedJson (Join-Path $c.output 'miner-build-proof.json') @{status='ACTUAL_OWN_HARNESS_COMPILED_NO_MINING_EXECUTION';config_sha256=$PhaseConfigSha;classes=$classes;class_files=$files;java_sources=$c.java_sources;classpath_sha256=$c.classpath_sha;argfile_sha256=Get-OwnedHash $argfile;javac_sha256=$c.javac_sha;java_sha256=$c.java_sha;native_exit=$result.native_exit;canonical_readback_before_after=$true;no_engine_execution=$true}
