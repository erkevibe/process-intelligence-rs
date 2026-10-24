param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$RunName,[ValidatePattern('^public-projection[0-9]{2}$')][string]$Projection='public-projection01')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. ./tools/sprint27/load-limited-broker.ps1
$root=[string]$PWD;$base=Join-Path $root '.local/sprint21/root/sprint27'
$old=Get-Content .local/sprint21/root/sprint25/preview-runtime-config07.json -Raw|ConvertFrom-Json -AsHashtable
$tools=Get-Content .local/sprint21/root/sprint25/pg-recovery-config04.json -Raw|ConvertFrom-Json -AsHashtable
$out=New-OwnedPrivateDirectory (Join-Path $base $RunName);$projectionOut=New-OwnedPrivateDirectory (Join-Path $base $Projection)
$c=@{workspace=$root;output=$out;deadline_utc='2026-10-24T17:14:49Z';session_seconds=900;commands=@();pins=@()}
$c.commands+=,@{label='project';program=$tools.python;sha256=(Get-FileHash $tools.python).Hash;arguments=@('-I','-B','tools/sprint27/publish-miner-evidence.py',$base,$projectionOut);directory=$root;environment=@{PYTHONNOUSERSITE='1';PYTHONDONTWRITEBYTECODE='1'};seconds=600;output_limit=1MB;service=$false;process_memory_limit_bytes=512MB}
$worker=Join-Path $root 'tools/sprint27/comparison-worker.ps1'
$files=@(Get-ChildItem tools/sprint27 -File)+@(Get-ChildItem src -Recurse -File -Filter '*.rs')+@(Get-ChildItem examples -Recurse -File -Filter '*.rs')+@(Get-Item Cargo.toml,Cargo.lock,tools/oracle/compare-quality-graphs.py,tools/oracle/validate-quality-net-graph.py,tools/sprint19/quality-reference.py)
foreach($name in @('rust02','alpha-original01','alpha-validation01','java01','projection02','java-scores02','inductive02','inductive-scores01','sv-original02','sv-validation01','sv-structured01','sv-audit02','inductive-audit03','audits01','alpha-audit-original03','alpha-audit-validation01','java-audit02','compile04','counter-calibration02','limit-calibration01','python-image-scope01','inputs01','inputs02','inputs03')){$files+=@(Get-ChildItem (Join-Path $base $name) -Recurse -File)}
$files+=@(Get-ChildItem (Join-Path $base '../sprint27-review') -File)
$files+=@(Get-Item fixtures/sprint26-miner/corpus.json,fixtures/sprint27-miner-validation/corpus.json,fixtures/sprint27-structured/corpus.json)
$c.pins=@($files|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash $_.FullName).Hash}})
$before=Assert-S22Capacity $c
if($before.root_allocation_bytes+64MB -gt (10GB-512MB) -or $before.allocation_bytes+64MB -gt (14GB-512MB) -or (Get-PSDrive C).Free -lt (8GB+64MB)){throw 'projection_reserve'}
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c
$session=New-OwnedPrivateDirectory (Join-Path $out 'session')
$command=@{label='worker';program=$old.pwsh;sha256=$old.pwsh_sha;arguments=@('-NoProfile','-File',$worker,'-TaskConfig',$config,'-TaskConfigSha',(Get-FileHash $config).Hash);directory=$root;environment=@{};seconds=850;output_limit=65536}
$r=Invoke-S22Broker $c $command $c.commands $session 'none'
if($r.failure -or $r.kill_fault -or $r.stop_reason -cne 'worker_exit' -or $r.records.Count -ne 2){throw 'projection_broker_failed'}
foreach($record in $r.records.Values){if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete){throw 'projection_capture_failed'}}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$after=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $out 'proof.json') @{status='S27_CURATED_PRIVATE_PUBLIC_EVIDENCE_PROJECTION_CLOSED';config_sha256=(Get-FileHash $config).Hash;records=$r.records;before=$before;after=$after;manifest_sha256=(Get-FileHash (Join-Path $projectionOut 'manifest.json')).Hash;not_yet_copied_to_public_tree=$true}
Write-Output 'S27_CURATED_PROJECTION_CLOSED'
