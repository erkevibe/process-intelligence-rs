param([Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$owned=Join-Path $workspace '.local/sprint18/service'
$output=[IO.Path]::GetFullPath($OutputPath)
if(!$output.StartsWith($owned+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'private_rust_attempt'}
Import-Module (Join-Path $PSScriptRoot 'public-service-runtime.psm1') -Force -DisableNameChecking
[void](New-OwnedPrivateDirectory $output)
[void](New-OwnedPrivateDirectory (Join-Path $output 'temp'))
$program=Join-Path $workspace '.local/sprint16/root/retained-observers01/full_service_observer-906A06C9.exe'
Assert-OwnedHash $program '906A06C95A87013FCE481FF3EC23054BADA9E5A9B5D81AAF8B5895527A5A1969'
$pwsh=(Get-Process -Id $PID).Path
Assert-OwnedHash $pwsh '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$manifests=@(@{path=(Join-Path $workspace 'fixtures/oracle-public-service/corpus.json');sha256='60878D96CDB6D3882FF1BC11CFA32E8207F2457B6C76C47C9FC73713AD08A648'},@{path=(Join-Path $workspace 'fixtures/oracle-public-service/supplement-flat/corpus.json');sha256='05AB614AAA1A047251D009C096801152B0258B072D8E65A156100A2761BE4202'})
$seen=@{};$plan=@()
foreach($manifest in $manifests){
 Assert-OwnedHash $manifest.path $manifest.sha256
 foreach($case in (Get-Content $manifest.path -Raw|ConvertFrom-Json -AsHashtable).corpus){
  $fixture=Join-Path (Split-Path $manifest.path) $case.file
  Assert-OwnedHash $fixture $case.sha256
  if($seen.ContainsKey($case.sha256)){continue};$seen[$case.sha256]=$true
  $name=[IO.Path]::GetFileNameWithoutExtension($fixture)
  if($name -cnotmatch '^[a-z][a-z0-9-]{0,39}$'){throw 'finite_rust_case_name'}
  $pins=@(@{path=$fixture;sha256=$case.sha256},@{path=$manifest.path;sha256=$manifest.sha256})
  $config=@{program=$program;program_sha256=Get-OwnedHash $program;arguments=@('--trusted-corpus',$fixture);working_directory=(Join-Path $output 'temp');cwd=(Join-Path $output 'temp');output_directory=(Join-Path $output $name);timeout_seconds=60;max_output_bytes=8MB;worker_go=$true;worker_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-worker.ps1');module_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-runtime.psm1');pwsh_sha256=Get-OwnedHash $pwsh;environment=@{TEMP=(Join-Path $output 'temp');TMP=(Join-Path $output 'temp')};pins=$pins;inputs=$pins}
  $configPath=Join-Path $output ($name+'.config.json');Write-OwnedJson $configPath $config
  $plan+=,@{id=$name;input_sha256=$case.sha256;fixture=$fixture;config=$configPath;config_sha256=Get-OwnedHash $configPath;capture_directory=$config.output_directory;reused_program_sha256=$config.program_sha256}
 }
}
$path=Join-Path $output 'execution-plan.json';Write-OwnedJson $path @{status='PREPARED_ONLY_NO_NATIVE_EXECUTION';cases=$plan;case_count=$plan.Count;runner_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-run.ps1')}
Write-Output (@{plan=$path;sha256=Get-OwnedHash $path;cases=$plan.Count}|ConvertTo-Json)
