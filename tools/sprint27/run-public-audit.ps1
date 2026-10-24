param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName,[ValidatePattern('^public-projection[0-9]{2}$')][string]$Projection='public-projection03')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$tools=Get-Content .local/sprint21/root/sprint25/pg-recovery-config04.json -Raw|ConvertFrom-Json -AsHashtable
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName);$package=Join-Path $base $Projection
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=600;commands=@();pins=@()}
$c.commands+=,@{label='audit';program=$tools.python;sha256=(Get-FileHash $tools.python).Hash;arguments=@('-I','-B','tools/sprint27/audit-public-miner.py',$package);directory=$root;environment=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'};seconds=300;output_limit=1MB;service=$false;process_memory_limit_bytes=512MB}
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
$files=@(Get-ChildItem tools/sprint27 -File)+@(Get-ChildItem $package -Recurse -File)+@(Get-Item fixtures/sprint26-miner/corpus.json,fixtures/sprint27-miner-validation/corpus.json,fixtures/sprint27-structured/corpus.json,tools/oracle/compare-quality-graphs.py,tools/oracle/validate-quality-net-graph.py,tools/sprint19/quality-reference.py)
$c.pins=@($files|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash $_.FullName).Hash}})
$before=Assert-S22Capacity $c
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=550;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 2){throw 'public_audit_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete){throw 'public_audit_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_PORTABLE_PROJECTED_EVIDENCE_AUDIT_CLOSED';config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;manifest_sha256=(Get-FileHash (Join-Path $package 'manifest.json')).Hash}
Write-Output 'S27_PORTABLE_PUBLIC_AUDIT_CLOSED'
