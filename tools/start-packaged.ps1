param([int]$Port=3000,[int]$PostgresPort=5433)
$ErrorActionPreference='Stop'
if($Port -lt 1 -or $Port -gt 65535 -or $PostgresPort -lt 1 -or $PostgresPort -gt 65535){throw 'Ports must be between 1 and 65535.'}
$taskRoot=Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $taskRoot
$taskManifest=Get-Content -LiteralPath (Join-Path $taskRoot 'build-manifest.json') -Raw|ConvertFrom-Json
foreach($taskFile in $taskManifest.files){
    $taskAbsolute=[IO.Path]::GetFullPath((Join-Path $taskRoot $taskFile.path))
    if(!$taskAbsolute.StartsWith($taskRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Manifest path is outside package.'}
    if(!(Test-Path -LiteralPath $taskAbsolute) -or (Get-FileHash -LiteralPath $taskAbsolute).Hash -ne $taskFile.sha256){throw "Package integrity check failed: $($taskFile.path)"}
}
& (Join-Path $PSScriptRoot 'setup-postgres.ps1') -Port $PostgresPort
$taskPrivate=Get-Content -LiteralPath (Join-Path $taskRoot '.local/postgres-private.json') -Raw|ConvertFrom-Json
$env:PI_DATABASE_URL=$taskPrivate.database_url
$taskPrivate=$null
$env:PORT=[string]$Port
$env:RUST_LOG='info'
Write-Output "Open http://127.0.0.1:$Port — create your account on first start. Stop the application with Ctrl+C."
try{& (Join-Path $taskRoot 'process-intelligence-rs.exe');$taskExit=$LASTEXITCODE}finally{Remove-Item Env:PI_DATABASE_URL -ErrorAction SilentlyContinue}
exit $taskExit
