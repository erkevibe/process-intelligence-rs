param([int]$Port=3000,[string]$LogFilter='info',[string]$Database='process_intelligence')
$ErrorActionPreference='Stop'
if($Port -lt 1 -or $Port -gt 65535){throw 'Port must be between 1 and 65535.'}
if($Database -cnotmatch '^(process_intelligence|pi_restore_[a-z0-9_]{1,50})$'){throw 'Use the local database or a named isolated restore.'}
$taskRoot=Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $taskRoot
$env:PORT=[string]$Port
$env:RUST_LOG=$LogFilter
& (Join-Path $PSScriptRoot 'setup-postgres.ps1')
if($LASTEXITCODE -ne 0){throw 'PostgreSQL setup failed'}
$taskPrivate=Get-Content -LiteralPath (Join-Path $taskRoot '.local/postgres-private.json') -Raw|ConvertFrom-Json
$env:PI_DATABASE_URL=$taskPrivate.database_url.Replace("dbname=process_intelligence ","dbname=$Database ")
$taskPrivate=$null
& (Join-Path $PSScriptRoot 'cargo.ps1') run --locked
exit $LASTEXITCODE

