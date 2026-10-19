param([Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$source=Join-Path $root 'tools/sprint12/mixed-recovery-phase.ps1'
$errors=$null;$tokens=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'phase_parse_error'}
$helper=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-MixedStateComparison'},$true)
if($helper.Count -ne 1){throw 'unique_comparison_helper_missing'}
if((Get-Command Compare).CommandType -ne 'Alias'){throw 'regression_requires_builtin_alias'}
Invoke-Expression $helper[0].Extent.Text
if((Get-Command Invoke-MixedStateComparison).CommandType -ne 'Function'){throw 'comparison_helper_dispatch'}
if(-not(Test-Path -LiteralPath $EvidenceDirectory -PathType Container)){throw 'new_private_evidence_directory_required'}
$out=(Resolve-Path -LiteralPath $EvidenceDirectory).Path
$c=@{node='fixture-node';node_sha='fixture-sha';state_compare='fixture-comparator';workspace=$root}
$script:calls=@()
function Invoke-OwnedPhaseCommand {
 param($Program,$ProgramSha,$Arguments,$WorkingDirectory,$OutputDirectory,$Label,$Environment,$Timeout,$Cap)
 if($Program -cne 'fixture-node' -or $Arguments.Count -ne 4 -or $Arguments[3] -cnotin @('exact','restore','crash')){throw 'comparison_argument_dispatch'}
 $script:calls+=@{mode=$Arguments[3];label=$Label}
 $target=Join-Path $OutputDirectory ($Label+'.stdout')
 if(Test-Path -LiteralPath $target){throw 'regression_output_exists'}
 [IO.File]::WriteAllText($target,'{"status":"STOCK_NAMED_COMPARISON_PASSED"}')
}
foreach($mode in @('exact','restore','crash')){Invoke-MixedStateComparison 'left' 'right' $mode ('dispatch-'+$mode)}
if($script:calls.Count -ne 3){throw 'dispatch_missing_calls'}
$result=@{status='RECOVERY_COMPARISON_COMMAND_DISPATCH_PASSED';cases=3;builtin_compare_alias_present=$true;limits=@('PowerShell name/argument dispatch regression only; mocked native command; no PostgreSQL or recovery acceptance')}
$result|ConvertTo-Json -Depth 5
