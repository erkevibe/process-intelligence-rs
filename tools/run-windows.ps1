param([int]$Port=3000,[string]$LogFilter='info')
$ErrorActionPreference='Stop'
if($Port -lt 1 -or $Port -gt 65535){throw 'Port must be between 1 and 65535.'}
$taskRoot=Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $taskRoot
$env:PORT=[string]$Port
$env:RUST_LOG=$LogFilter
& (Join-Path $PSScriptRoot 'cargo.ps1') run --locked
exit $LASTEXITCODE
