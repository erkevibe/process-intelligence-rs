param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-phase-support.psm1') -Force -DisableNameChecking
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output
if($c.inputs -cne (Join-Path $c.workspace '.local/sprint21/root/capacity-inputs01')){throw 'input_scope'}
$parse='import ast,pathlib; [ast.parse(pathlib.Path(p).read_text(encoding="utf-8"),filename=p) for p in ("tools/sprint21-capacity/prepare-inputs.py","tools/sprint21-capacity/capacity-http.py")]; print("TWO_SOURCE_AST_PARSE_PASS")'
[void](Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B','-c',$parse) $c.workspace $c.output 'parse' @{} 15 1MB)
[void](Invoke-OwnedPhaseCommand $c.python $c.python_sha @('-I','-B',(Join-Path $c.workspace 'tools/sprint21-capacity/prepare-inputs.py'),'--workspace',$c.workspace,'--output',$c.inputs) $c.workspace $c.output 'prepare' @{} 35 1MB)
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'prepare-proof.json') @{status='ACTUAL_FIXED_INPUT_PREPARATION';input_manifest_sha256=(Get-FileHash (Join-Path $c.inputs 'manifest.json')).Hash;measurement_started=$false;converter_executed=$false}