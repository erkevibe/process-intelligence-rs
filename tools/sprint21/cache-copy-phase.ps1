param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
$root=Join-Path $c.workspace '.local/sprint21/root'
if($c.cargo_home -cne (Join-Path $root 'cargo') -or $c.target -cne (Join-Path $root 'target') -or $c.cache_source -cne (Join-Path $c.workspace '.local/sprint20/root/cargo')){throw 'cache_scope'}
Assert-OwnedPrivateDirectory $c.output
if($c.temp -cne (Join-Path $root 'temp')){throw 'temp_scope'}
if(Test-Path -LiteralPath $c.temp){Assert-OwnedPrivateDirectory $c.temp}else{[void](New-OwnedPrivateDirectory $c.temp)}
[void](New-OwnedPrivateDirectory $c.target)
$cache=New-OwnedPrivateDirectory $c.cargo_home
Assert-OwnedNoReparse $c.cache_source
$files=@(Get-ChildItem -LiteralPath $c.cache_source -File -Recurse -Force)
if($files.Count -gt 12000 -or ($files|Measure-Object Length -Sum).Sum -gt 256MB){throw 'cache_bounds'}
$rows=[Collections.Generic.List[object]]::new()
foreach($file in $files){
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc -or (Get-PSDrive C).Free -lt 8GB){throw 'cache_stop'}
 Assert-OwnedNoReparse $file.FullName
 $rel=[IO.Path]::GetRelativePath($c.cache_source,$file.FullName)
 $dst=Join-Path $cache $rel
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dst))
 $hash=Get-OwnedHash $file.FullName
 [IO.File]::Copy($file.FullName,$dst,$false)
 Assert-OwnedHash $dst $hash;Assert-OwnedHash $file.FullName $hash
 $rows.Add(@{path=$rel;bytes=$file.Length;sha256=$hash})
}
Write-OwnedJson (Join-Path $c.output 'cargo-copy.json') @{count=$rows.Count;files=$rows.ToArray();source_read_only=$true;scope='S20 cache copied into new S21 sole-SID home; no installs, parser, compiler or mining execution'}
