param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
$source=New-OwnedPrivateDirectory $c.source_directory
function Get-BuildInputs {
 $result=[Collections.Generic.List[IO.FileInfo]]::new()
 foreach($name in @('Cargo.toml','Cargo.lock')){$result.Add([IO.FileInfo]::new((Join-Path $c.workspace $name)))}
 foreach($name in @('src','static','templates','examples','fixtures','tests','migrations')){
  $dir=Join-Path $c.workspace $name
  if(Test-Path -LiteralPath $dir){
   Assert-OwnedNoReparse $dir
   foreach($item in Get-ChildItem -LiteralPath $dir -File -Recurse -Force){$result.Add($item)}
  }
 }
 foreach($name in @('tools/sprint19/quality-miner-project.py','tools/sprint19/schema-hint.py','tools/sprint19/quality-di.py')){
  $result.Add([IO.FileInfo]::new((Join-Path $c.workspace $name)))
 }
 return @($result|Sort-Object FullName)
}
$files=Get-BuildInputs
if($files.Count -gt 5000 -or ($files|Measure-Object Length -Sum).Sum -gt 64MB){throw 'source_bound'}
$rows=[Collections.Generic.List[object]]::new()
foreach($file in $files){
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc -or (Get-PSDrive C).Free -lt 8GB){throw 'source_copy_stop'}
 Assert-OwnedNoReparse $file.FullName
 $relative=[IO.Path]::GetRelativePath($c.workspace,$file.FullName)
 $dest=Join-Path $source $relative
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
 $hash=Get-OwnedHash $file.FullName
 [IO.File]::Copy($file.FullName,$dest,$false)
 Assert-OwnedHash $dest $hash;Assert-OwnedHash $file.FullName $hash
 $rows.Add(@{path=$relative.Replace('\','/');bytes=$file.Length;sha256=$hash})
}
$after=Get-BuildInputs
if($after.Count -ne $files.Count){throw 'source_set_changed'}
foreach($row in $rows){Assert-OwnedHash (Join-Path $c.workspace $row.path) $row.sha256}
$archive=Join-Path $c.output 'source.zip'
if(Test-Path -LiteralPath $archive){throw 'archive_collision'}
[IO.Compression.ZipFile]::CreateFromDirectory($source,$archive,[IO.Compression.CompressionLevel]::Fastest,$false)
if((Get-Item -LiteralPath $archive).Length -gt 64MB){throw 'archive_bound'}
Write-OwnedJson (Join-Path $c.output 'source-inventory.json') @{schema_version=1;files=$rows.ToArray();count=$rows.Count;source_archive_sha256=Get-OwnedHash $archive;config_sha256=$PhaseConfigSha;claim='Exact bounded build-input copy; all workspace inputs unchanged during freeze. Not the complete Git repository or test acceptance.'}
