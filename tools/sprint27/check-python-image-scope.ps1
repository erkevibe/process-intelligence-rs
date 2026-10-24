param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$tools=Get-Content .local/sprint21/root/sprint25/pg-recovery-config04.json -Raw|ConvertFrom-Json -AsHashtable
$reference=Get-Content .local/sprint19/root/prep01/reference-install-config01.json -Raw|ConvertFrom-Json -AsHashtable
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName)
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=180;commands=@();pins=@()}
$code='import os,json,sys; print(json.dumps({"runtime_pid":os.getpid(),"version":list(sys.version_info[:3])}))'
foreach($entry in @(@{label='venv-pid';program=$reference.python;sha=$reference.python_sha},@{label='direct-pid';program=$tools.python;sha=(Get-FileHash $tools.python).Hash})){
 $c.commands+=,@{label=$entry.label;program=$entry.program;sha256=$entry.sha;arguments=@('-I','-B','-c',$code);directory=$root;environment=@{};seconds=15;output_limit=65536;service=$false;process_memory_limit_bytes=64MB}
}
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
foreach($path in @($worker,(Join-Path $root 'tools/sprint27/check-python-image-scope.ps1'),(Join-Path $root 'tools/sprint27/load-limited-broker.ps1'))){$c.pins+=,@{path=$path;sha256=(Get-FileHash $path).Hash}}
$before=Assert-S22Capacity $c
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=150;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 3){throw 'image_scope_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete){throw 'image_scope_capture_failed'}}
$venv=Get-Content (Join-Path $session 'venv-pid.stdout') -Raw|ConvertFrom-Json;$direct=Get-Content (Join-Path $session 'direct-pid.stdout') -Raw|ConvertFrom-Json
if($venv.runtime_pid -eq $r.records['venv-pid'].pid -or $direct.runtime_pid -ne $r.records['direct-pid'].pid -or ($venv.version|ConvertTo-Json -Compress) -cne ($direct.version|ConvertTo-Json -Compress)){throw 'expected_scope_control_not_observed'}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_WINDOWS_VENV_REDIRECTOR_SCOPE_CONFIRMED';config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;venv_runtime_pid_differs_from_retained_image=$true;direct_runtime_pid_matches_retained_image=$true;python_versions_identical=$true;conclusion='Venv native image lifetime CPU/RAM is redirector-only and must not be presented as PM4Py engine CPU/RAM. No process-tree total was measured.'}
Write-Output 'S27_PYTHON_IMAGE_SCOPE_CONFIRMED'
