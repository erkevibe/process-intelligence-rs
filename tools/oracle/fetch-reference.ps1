param([string]$PrivateDir='.local/sprint03/oracle')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $root
$lock=Get-Content (Join-Path $PSScriptRoot 'reference.lock.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force $PrivateDir | Out-Null
foreach($source in $lock.sources){
 $destination=Join-Path $PrivateDir $source.name
 if(-not(Test-Path $destination)){
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/apromore/ApromoreCore/$($lock.legacy_commit)/$($source.path)" -OutFile $destination -TimeoutSec 30
 }
 if((Get-FileHash $destination -Algorithm SHA256).Hash -ne $source.sha256){throw "Pinned reference source mismatch: $($source.name)"}
}
Write-Output 'Pinned private reference sources verified. No runtime source copied.'
