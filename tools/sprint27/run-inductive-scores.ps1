param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$buildConfig=Get-Content (Join-Path $base 'compile03-config.json') -Raw|ConvertFrom-Json -AsHashtable
$build=Get-Content (Join-Path $base 'compile03/proof.json') -Raw|ConvertFrom-Json -AsHashtable
if($build.status -cne 'DIRECT_OWNED_CARGO_COMMANDS_CLOSED' -or @($build.records|Where-Object {$_.native_exit -ne 0 -or !$_.stdout_complete -or !$_.stderr_complete}).Count){throw 'release_build_required'}
foreach($pin in $buildConfig.pins){Assert-OwnedHash $pin.path $pin.sha256}
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$run=Join-Path $base 'inductive02';$mining=Get-Content (Join-Path $run 'proof.json') -Raw|ConvertFrom-Json -AsHashtable
$raw=Get-Content (Join-Path $run 'config.json') -Raw|ConvertFrom-Json -AsHashtable
Assert-OwnedHash (Join-Path $run 'config.json') $mining.config_sha256
if($mining.status -cne 'S27_ACTUAL_PM4PY_IM_CAPTURED_PENDING_INDEPENDENT_AUDIT' -or $mining.records.Count -ne 29){throw 'mining_required'}
foreach($pin in $raw.pins){Assert-OwnedHash $pin.path $pin.sha256}
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName)
$program=Join-Path $root '.local/sprint21/root/target/release/examples/miner_score_inductive.exe';$sha=(Get-FileHash $program).Hash
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=1000;commands=@();pins=$buildConfig.pins}
foreach($command in $raw.commands){
 if($command.label -cnotmatch '^im-(original|validation)-r[12]-[a-z-]+$'){throw 'mining_label'}
 $set=$Matches[1];$case=[IO.Path]::GetFileNameWithoutExtension($command.arguments[-2]);if($case -cnotmatch '^[a-z_]+$'){throw 'case_identity'}
 $result=Join-Path $run ($command.label+'/result.json');$source=Get-Content $result -Raw|ConvertFrom-Json -AsHashtable
 if($source.status -in @('no_data','projection_refused')){continue}
 if($source.status -cne 'model_projected'){throw 'projection_not_available'}
 $inputs=Join-Path $base $(if($set -eq 'original'){'inputs01'}else{'inputs02'});$input=Join-Path $inputs ($case+'.json');$model=Join-Path $run ($command.label+'/model.json')
 Assert-OwnedHash $model $source.model_input_sha256.ToUpperInvariant()
 foreach($path in @($input,$model,$result)){$c.pins+=,@{path=$path;sha256=(Get-FileHash $path).Hash}}
 $directory=New-OwnedPrivateDirectory (Join-Path $out $command.label)
 $c.commands+=,@{label=$command.label;program=$program;sha256=$sha;arguments=@($input,$model,$directory);directory=$root;environment=@{RAYON_NUM_THREADS='1';TEMP=$buildConfig.environment.TEMP;TMP=$buildConfig.environment.TMP};seconds=60;output_limit=1MB;service=$false;process_memory_limit_bytes=512MB}
}
if($c.commands.Count -lt 1 -or $c.commands.Count -gt 24){throw 'bounded_projection_coverage'}
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
foreach($path in @($worker,(Join-Path $root 'tools/sprint27/load-limited-broker.ps1'),(Join-Path $root 'tools/sprint27/run-inductive-scores.ps1'),(Join-Path $run 'proof.json'))){$c.pins+=,@{path=$path;sha256=(Get-FileHash $path).Hash}}
$before=Assert-S22Capacity $c
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=950;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne ($c.commands.Count+1)){throw 'score_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or !$record.lifetime_memory_after_exit){throw 'score_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_PROJECTED_PM4PY_IM_MODELS_SCORED_PENDING_INDEPENDENT_AUDIT';config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;mining_proof_sha256=(Get-FileHash (Join-Path $run 'proof.json')).Hash}
Write-Output 'S27_PM4PY_IM_MODEL_SCORES_CLOSED'
