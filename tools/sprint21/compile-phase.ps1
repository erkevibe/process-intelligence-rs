param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
if($c.source_directory -cne $c.workspace -or $c.target -cne (Join-Path $c.workspace '.local/sprint21/root/target')){throw 'compile_scope'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$manifest=Join-Path $c.source_directory 'Cargo.toml'
$envAdd=@{RAYON_NUM_THREADS='1'}
$results=[Collections.Generic.List[object]]::new()
foreach($task in $c.compile_tasks){
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$c.phase_deadline_utc){throw 'runtime_freeze'}
 $arguments=@();$seconds=1200;$cap=8MB
 switch([string]$task.mode){
  'fmt-check' {$arguments=@('fmt','--all','--manifest-path',$manifest,'--','--check');$seconds=120;$cap=2MB}
  'fmt-apply' {$arguments=@('fmt','--all','--manifest-path',$manifest);$seconds=120;$cap=2MB}
  'check' {$arguments=@('check','--offline','--locked','--all-targets','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2')}
  'build' {$arguments=@('build','--offline','--locked','--all-targets','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2')}
  'test' {
   $arguments=@('test','--offline','--locked','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2')
   if($task.ContainsKey('integration_test')){if([string]$task.integration_test -notmatch '^[a-z0-9_]+$'){throw 'test_name'};$arguments+=@('--test',[string]$task.integration_test)}else{$arguments+='--lib'}
   if($task.ContainsKey('filter')){if([string]$task.filter -notmatch '^[A-Za-z0-9_:]+$'){throw 'test_filter'};$arguments+=[string]$task.filter}
   if($task.ContainsKey('ignored') -and $task.ignored){$arguments+=@('--','--ignored','--test-threads=1')}else{$arguments+=@('--','--test-threads=1')}
  }
  'clippy' {$arguments=@('clippy','--offline','--locked','--all-targets','--manifest-path',$manifest,'--target-dir',$c.target,'--jobs','2','--','-D','warnings')}
  default {throw 'compile_mode'}
 }
 if([string]$task.label -notmatch '^[a-z][a-z0-9-]{0,63}$'){throw 'task_label'}
 $r=Invoke-OwnedPhaseCommand $c.cargo $c.cargo_sha $arguments $c.source_directory $c.output $task.label $envAdd $seconds $cap
 $results.Add(@{mode=$task.mode;label=$task.label;native_exit=$r.native_exit;stdout_complete=$r.stdout_complete;stderr_complete=$r.stderr_complete})
}
# Formatting deliberately modifies source; callers must not pin files it rewrites.
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'compile-proof.json') @{status='ACTUAL_BOUNDED_CARGO_COMMANDS';config_sha256=$PhaseConfigSha;commands=$results.ToArray();target=$c.target;offline=$true;locked=$true;acceptance_not_claimed=$true}
