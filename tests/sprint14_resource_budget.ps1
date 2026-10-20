param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'tools/sprint14/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'tools/sprint14/resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $OutputDirectory
$module=Get-Module resource-phase-budget
$checks=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Name){if(!$Condition){throw ('resource_regression_'+$Name)};$checks.Add(@{name=$Name;status='PASS'})}
function Case([string]$Name){
 $dir=New-OwnedPrivateDirectory (Join-Path $OutputDirectory $Name)
 return @{out=(New-OwnedPrivateDirectory (Join-Path $dir 'out'));install=(New-OwnedPrivateDirectory (Join-Path $dir 'install'));capture_files=@('known.stdout');install_reservation=2MB;capture_reservation=2MB}
}
function File([string]$Path,[long]$Length){
 [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))|Out-Null
 $f=[IO.File]::Open($Path,'CreateNew','Write','None');try{$f.SetLength($Length);$f.Flush($true)}finally{$f.Dispose()}
}
function Totals([hashtable]$Proof,[bool]$Final=$true){& $module {param($p,$f) Get-PhaseBudgetLogical @($p.out,$p.install) $p $f} $Proof $Final}
function Refuses([hashtable]$Proof,[string]$Code,[string]$Name){
 $actual='';try{[void](Totals $Proof $false)}catch{$actual=$_.Exception.Message}
 Check ($actual -ceq $Code) $Name
}
$p=Case 'whole-scope'
File (Join-Path $p.out 'known.stdout') 4
File (Join-Path $p.out 'unknown.stdout') 2
File (Join-Path $p.out 'nested/known.stdout') 5
File (Join-Path $p.out 'phase-fresh-native-baseline.jsonl') 7
File (Join-Path $p.out 'runner.stdout') 6
File (Join-Path $p.install '.local/pgdata/pg_wal/segment') 3
$t=Totals $p
Check ($t.total_bytes -eq 27 -and $t.groups.install -eq 3 -and $t.groups.capture -eq 4 -and $t.groups.inventory -eq 7 -and $t.groups.outer -eq 6 -and $t.groups.other -eq 7) 'all_groups_conserve_all_bytes_including_nested_named_stdout'
File (Join-Path $p.install '.local/postgres-private.json') 8
$t=Totals $p
Check ($t.groups.install -eq 11 -and $t.total_bytes -eq 35) 'whole_install_includes_private_metadata_without_extension_exclusion'
$p=Case 'unlisted-output'
File (Join-Path $p.out 'not-in-allowlist.stdout') (33MB)
Refuses $p 'phase_budget_install_capture_or_metadata_reservation' 'unknown_stdout_cannot_evade_other32MiB'
$t=Totals $p
Check ($t.groups.other -eq 33MB -and $t.groups.capture -eq 0 -and $t.total_bytes -eq 33MB) 'final_other64MiB_counter_retains_complete_unknown_output'
$p=Case 'outer-limit'
File (Join-Path $p.out 'runner.stdout') (16MB+1)
Refuses $p 'phase_budget_outer_stream_max' 'outer_stream_limit_is_not_other_or_capture'
$p=Case 'capture-limit'
File (Join-Path $p.out 'known.stdout') (2MB+1)
Refuses $p 'phase_budget_install_capture_or_metadata_reservation' 'allowlisted_capture_still_has_full_cap'
$p=Case 'install-limit'
File (Join-Path $p.install 'unexpected.extension') (2MB+1)
Refuses $p 'phase_budget_install_capture_or_metadata_reservation' 'all_install_paths_charged_before_exceeding_peak'
$p=Case 'empty'
Check ((Totals $p).total_bytes -eq 0) 'empty_scope_does_not_invent_byte_charge'
Write-OwnedJson (Join-Path $OutputDirectory 'regression-result.json') @{utc=[DateTime]::UtcNow.ToString('o');checks=$checks.ToArray();scope='Real new benign files / actual classification function only; length fixtures have no DB content; not native-allocation calibration, PG, peak or product acceptance'}
@{status='S14_RESOURCE_CLASSIFICATION_REGRESSION_PASSED';checks=$checks.Count}|ConvertTo-Json -Compress
