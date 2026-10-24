param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha,[Parameter(Mandatory)][string]$Nonce)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$go=[Console]::In.ReadLineAsync();if(!$go.Wait(30000) -or $go.Result -cne ('GO '+$Nonce)){throw 'collector_outer_job_not_admitted'}
if((Get-FileHash -LiteralPath $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'source_pin'}}
Import-Module (Join-Path $PSScriptRoot 'measure-broker.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
$before=Assert-S22Capacity $c;Write-OwnedJson (Join-Path $c.output 'resource-before.json') $before
$rows=[Collections.Generic.List[object]]::new()
foreach($scenario in @('service','absolute','memory')){
 $out=New-OwnedPrivateDirectory (Join-Path $c.output $scenario)
 $worker=@{label='worker';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'adapter-worker.ps1'),'-Scenario',$scenario,'-ExpectedImage',$c.pwsh,'-Output',$out);directory=$c.workspace;environment=@{TEMP=$c.temp;TMP=$c.temp};seconds=60;output_limit=16384}
 $mode=if($scenario -ceq 'service'){'normal'}else{'hang'}
 $child=@{label='child';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'control-child.ps1'),'-Mode',$mode);directory=$c.workspace;environment=@{};seconds=60;output_limit=16384;service=($scenario -in @('service','memory'))}
 $control=if($scenario -ceq 'absolute'){'absolute-stop'}else{'none'}
 $r=Invoke-S22Broker $c $worker @($child) $out $control
 $expected=switch($scenario){service{'unexpected_service_exit'};absolute{'pg_stop_absolute_deadline'};memory{'worker_exit'}}
 if($r.kill_fault -or $r.stop_reason -cne $expected -or ($scenario -ceq 'absolute' -and $r.failure -cne 'pg_stop_absolute_deadline') -or ($scenario -cne 'absolute' -and $r.failure)){throw ('adapter_failed_'+$scenario)}
 foreach($label in @('worker','child')){if(!$r.records.ContainsKey($label) -or !$r.records[$label].stdout_complete -or !$r.records[$label].stderr_complete){throw 'adapter_full_capture_required'}}
 $expectedWorker=if($scenario -ceq 'memory'){0}else{137};$expectedChild=if($scenario -ceq 'service'){0}else{137}
 if($r.records.worker.native_exit -ne $expectedWorker -or $r.records.child.native_exit -ne $expectedChild){throw 'adapter_native_exit'}
 if($scenario -ceq 'memory'){
  $path=Join-Path $out 'memory.ndjson';if((Get-Item -LiteralPath $path).Length -gt 4MB){throw 'memory_byte_bound'}
  $lines=@(Get-Content -LiteralPath $path|ForEach-Object{$_|ConvertFrom-Json -AsHashtable -DateKind String})
  $proof=Get-Content -LiteralPath (Join-Path $out 'memory-proof.json') -Raw|ConvertFrom-Json -AsHashtable
  if($lines[0].kind -cne 'header' -or $lines[-1].kind -cne 'complete' -or !$lines[-1].target_still_alive -or $lines[-1].samples -ne $proof.samples -or $proof.samples -ne $lines.Count-2 -or (Get-FileHash $path).Hash -cne $proof.sha256 -or !$proof.wrong_identity_refused -or !$proof.dead_target_partial){throw 'memory_complete_footer_or_hash'}
 }
 $rows.Add(@{scenario=$scenario;expected_stop=$expected;broker_sha256=Get-OwnedHash (Join-Path $out 'broker-result.json');root_observed_pass=$true})
}
$after=Assert-S22Capacity $c;foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'adapter-preflight-report.json') @{status='ROOT_OBSERVED_THREE_ADAPTER_CONTROLS_REQUIRES_INDEPENDENT_ACCEPTANCE';rows=$rows.ToArray();before=$before;after=$after;postgres_or_product_started=$false;measurement_admitted=$false;utc=[DateTimeOffset]::UtcNow.ToString('o')}
