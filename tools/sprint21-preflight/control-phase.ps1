param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($module in @('owned-runtime.psm1','owned-phase-support.psm1')){Import-Module (Join-Path $c.workspace ('tools/sprint21/'+$module)) -Force -DisableNameChecking}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output
$wrapper=Join-Path $PSScriptRoot 'run.ps1'
$rows=[Collections.Generic.List[object]]::new()
$codes=@('ACCEPTED','required_field_linker_self','pin_sha_hex','pin_sha_hex','duplicate_normalized_pin','pin_identity')
for($number=1;$number -le 6;$number++){
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc -or (Get-PSDrive C).Free -lt 8GB){throw 'control_deadline_or_disk'}
 $label='PREFLIGHT'+$number.ToString('00')
 $dir=New-OwnedPrivateDirectory (Join-Path $c.output $label)
 $fake=Join-Path $dir 'synthetic-not-executable.txt';$phase=Join-Path $dir 'synthetic-never-executed.ps1'
 [IO.File]::WriteAllText($fake,'Synthetic data, not an executable.',[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText($phase,'# Synthetic fixture: must never execute.',[Text.UTF8Encoding]::new($false))
 $fakeSha=Get-OwnedHash $fake;$phaseSha=Get-OwnedHash $phase
 $fixture=@{workspace=$c.workspace;pwsh=$fake;pwsh_sha=$fakeSha;rustup_home=$dir;cargo_home=$dir;target=$dir;temp=$dir;toolchain_bin=$dir;linker_self=$dir;linker_bin=$dir;dlltool=$fake;linker=$fake;phase=$phase;output=(Join-Path $dir 'must-not-be-created');phase_deadline_utc=[DateTimeOffset]::UtcNow.AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");pins=@(@{path=$fake;sha256=$fakeSha},@{path=$phase;sha256=$phaseSha})}
 switch($number){
  2 {foreach($field in @('linker_self','linker_bin','dlltool','linker')){$fixture.Remove($field)}}
  3 {$fixture.pins[0].sha256=$fakeSha.ToLowerInvariant()}
  4 {$fixture.pins[0].sha256=('G'*64)}
  5 {$fixture.pins+=@{path=(Join-Path $dir './synthetic-not-executable.txt');sha256=('F'*64)}}
  6 {[IO.File]::WriteAllText($phase,'Changed synthetic bytes.',[Text.UTF8Encoding]::new($false))}
 }
 $file=Join-Path $dir 'fixture-config.json'
 [IO.File]::WriteAllText($file,($fixture|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
 $before=Get-OwnedHash $file
 $arguments=@('-NoProfile','-File',$wrapper,'-Workspace',$c.workspace,'-Config',$file,'-ConfigSha',$before,'-Python',$c.python,'-PythonSha',$c.python_sha)
 if($number -eq 1){$arguments+='-CheckOnly'}
 $child=Start-OwnedCapturedProcess -Program $c.pwsh -ProgramSha256 $c.pwsh_sha -Arguments $arguments -WorkingDirectory $c.workspace -OutputDirectory $dir -Label wrapper -MaxOutputBytes 1MB
 $stop=[DateTimeOffset]::UtcNow.AddSeconds(15);$stopped=$false
 while(!$child.Process.WaitForExit(100)){
  if([DateTimeOffset]::UtcNow -ge $stop -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){
   $stopped=$true;$child.Process.Kill($true);if(!$child.Process.WaitForExit(10000)){throw 'control_stop_timeout'};break
  }
 }
 $record=Complete-OwnedCapturedProcess $child
 if($stopped -or !$record.stdout_complete -or !$record.stderr_complete -or $record.output_limit -or $record.capture_fault -or $record.drain_timeout){throw 'control_capture_failed'}
 $expected=if($number -eq 1){0}else{2}
 $stdout=[IO.File]::ReadAllText((Join-Path $dir 'wrapper.stdout'))
 $result=$stdout|ConvertFrom-Json -AsHashtable -DateKind String
 if($record.native_exit -ne $expected -or $stdout.Contains('RUNNER_DELEGATION') -or (Get-Item (Join-Path $dir 'wrapper.stderr')).Length -ne 0 -or (Test-Path -LiteralPath $fixture.output) -or (Get-OwnedHash $file) -cne $before){throw 'control_gate_or_input_changed'}
 if($number -eq 1){if($result.status -cne 'CONFIGURATION_PREFLIGHT_ACCEPTED'){throw 'positive_control'}}
 elseif($result.status -cne 'CONFIGURATION_PREFLIGHT_REJECTED' -or $result.code -cne $codes[$number-1] -or $result.runner_delegated -ne $false){throw 'negative_control'}
 $rows.Add(@{id=$label;native_exit=$record.native_exit;expected_exit=$expected;config_sha256=$before;config_after_sha256=Get-OwnedHash $file;check_only=($number -eq 1);status=$result.status;code=$codes[$number-1];runner_marker_absent=$true;runner_output_absent=$true;all_streams_eof=$true;stdout_sha256=$record.stdout_sha256;stderr_sha256=$record.stderr_sha256})
}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'preflight-controls-proof.json') @{status='SIX_FINITE_SYNTHETIC_PREFLIGHT_CONTROLS_PASS';controls=$rows.ToArray();feature_processes_started=$false;existing_runner_delegated=$false;historical_configs_rewritten=$false;historical_unknowns_reconstructed=$false;config_sha256=$PhaseConfigSha;utc=[DateTimeOffset]::UtcNow.ToString('o')}
