param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha,[Parameter(Mandatory)][string]$Nonce)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$go=[Console]::In.ReadLineAsync()
if(!$go.Wait(30000) -or $go.Result -cne ('GO '+$Nonce)){throw 'collector_outer_job_not_admitted'}
if((Get-FileHash -LiteralPath $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if([string]$PWD -cne $c.workspace -or [DateTimeOffset]$c.deadline_utc -gt [DateTimeOffset]'2026-10-23T09:53:31Z'){throw 's22_scope_deadline'}
foreach($p in $c.pins){if((Get-FileHash -LiteralPath $p.path).Hash -cne $p.sha256){throw 'source_pin'}}
Import-Module (Join-Path $PSScriptRoot '../sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'broker.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
$before=Assert-S22Capacity $c
Write-OwnedJson (Join-Path $c.output 'resource-before.json') $before
$rows=[Collections.Generic.List[object]]::new()
foreach($id in @('OWN-01','OWN-02','OWN-03','OWN-04','OWN-05','OWN-06','OWN-06B')){
 $out=New-OwnedPrivateDirectory (Join-Path $c.output $id.ToLowerInvariant())
 $mode=if($id -ceq 'OWN-01' -or $id -ceq 'OWN-06'){'normal'}elseif($id -ceq 'OWN-04'){'flood'}else{'hang'}
 $worker=@{label='worker';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'control-worker.ps1'));directory=$c.workspace;environment=@{};output_limit=16384;seconds=60}
 $child=@{label='child';program=$c.pwsh;sha256=$c.pwsh_sha;arguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'control-child.ps1'),'-Mode',$mode);directory=$c.workspace;environment=@{};output_limit=4096;seconds=$(if($id -ceq 'OWN-03'){2}else{60});deny_admission=($id -ceq 'OWN-06')}
 if($id -ceq 'OWN-06B'){$child.control_fault='after-native-identity'}
 $control=if($id -ceq 'OWN-02'){'kill-worker'}elseif($id -ceq 'OWN-05'){'guard-failure'}else{'none'}
 $result=Invoke-S22Broker $c $worker @($child) $out $control
 $mandatory=$id -in @('OWN-01','OWN-02','OWN-03','OWN-05')
 $saved=$result.records.ContainsKey('child') -and $result.records.ContainsKey('worker')
 $exact=$saved
 if($saved){foreach($record in $result.records.Values){if(!$record.stdout_complete -or !$record.stderr_complete -or $record.drain_timeout -or $record.source_status -cne 'captured'){$exact=$false}}}
 $reason=$result.stop_reason
 $expectedReason=switch($id){'OWN-01'{'worker_exit'};'OWN-02'{'worker_exit'};'OWN-03'{'child_timeout'};'OWN-04'{'output_or_capture_fault'};'OWN-05'{'resource_guard_failure'};'OWN-06'{'ownership_confirmation_withheld'};'OWN-06B'{'spawn_admission_failure'}}
 $pass=($reason -ceq $expectedReason -and $saved -and !$result.kill_fault -and !$result.failure)
 if($id -ceq 'OWN-06B'){$pass=$reason -ceq $expectedReason -and $saved -and !$result.kill_fault -and $result.failure -ceq 'spawn_admission_failure' -and !$result.records.child.resumed -and $result.records.child.source_status -ceq 'missing_or_fault' -and $result.records.child.native_creation_filetime -gt 0}
 if($mandatory){$pass=$pass -and $exact}
 if($id -ceq 'OWN-01'){$pass=$pass -and $result.records.child.native_exit -eq 0 -and $result.records.worker.native_exit -eq 0}
 if($id -ceq 'OWN-04'){$pass=$pass -and $result.records.child.stdout_truncated -and !$result.records.child.stdout_complete -and $result.records.child.stdout_bytes_persisted -eq 4096}
 if($id -ceq 'OWN-06'){$pass=$pass -and !$result.records.child.resumed -and $result.records.child.stdout_bytes_persisted -eq 0 -and $result.records.child.stderr_bytes_persisted -eq 0}
 if($id -ceq 'OWN-05'){$pass=$pass -and $result.guard_failure -and $result.guard_failure.expected_owned_sharing_failure}
 $rows.Add(@{id=$id;root_observed_pass=$pass;stop_reason=$reason;mandatory_full_capture=$mandatory;actual_child_record_saved=$saved;full_capture=$exact;output_relative=$id.ToLowerInvariant();broker_sha256=Get-OwnedHash (Join-Path $out 'broker-result.json')})
 if(!$pass){Write-OwnedJson (Join-Path $c.output 'controls-partial.json') @{status='FAILED_STOP_NO_MEASUREMENT';rows=$rows.ToArray()};throw ('control_failed_'+$id)}
 if($id -ceq 'OWN-05'){
  # The intentional sharing lock has been released by the completed broker.
  # A new independent control is permitted only after the real unchanged guard
  # proves known resources again; this is not a blind retry of an unknown fault.
  Write-OwnedJson (Join-Path $c.output 'resource-after-controlled-denial.json') (Assert-S22Capacity $c)
 }
}
$after=Assert-S22Capacity $c
foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256}
Write-OwnedJson (Join-Path $c.output 'controls-report.json') @{status='ROOT_OBSERVED_SIX_CONTROL_FAMILIES_SEVEN_SCENARIOS_REQUIRES_INDEPENDENT_ACCEPTANCE';rows=$rows.ToArray();historical_unknowns=6;historical_unknowns_repaired=$false;before=$before;after=$after;measurement_admitted=$false;utc=[DateTimeOffset]::UtcNow.ToString('o')}
