param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$tools=Get-Content .local/sprint21/root/sprint25/pg-recovery-config04.json -Raw|ConvertFrom-Json -AsHashtable
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName);$inputs=New-OwnedPrivateDirectory (Join-Path $base 'inputs03')
$corpus=Join-Path $root 'fixtures/sprint27-structured/corpus.json';Assert-OwnedHash $corpus 'A6DB9120518D4ADFDFCB2648C6BBA08EFBD2757B4A36BE50AAFB50DB795018E6'
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=180;commands=@();pins=@()}
$c.commands+=,@{label='prepare';program=$tools.python;sha256=(Get-FileHash $tools.python).Hash;arguments=@('-I','-B','tools/sprint27/prepare-inputs.py',$corpus,$inputs);directory=$root;environment=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'};seconds=30;output_limit=65536;service=$false;process_memory_limit_bytes=64MB}
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
foreach($path in @($worker,$corpus,(Join-Path $root 'tools/sprint27/prepare-inputs.py'),(Join-Path $root 'tools/sprint27/prepare-structured-inputs.ps1'),(Join-Path $root 'tools/sprint27/load-limited-broker.ps1'))){$c.pins+=,@{path=$path;sha256=(Get-FileHash $path).Hash}}
$before=Assert-S22Capacity $c
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=150;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 2){throw 'prepare_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete){throw 'prepare_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_THIRD_PROSPECTIVE_CORPUS_INPUTS_PREPARED';config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;manifest_sha256=(Get-FileHash (Join-Path $inputs 'manifest.json')).Hash}
Write-Output 'S27_THIRD_INPUTS_PREPARED'
