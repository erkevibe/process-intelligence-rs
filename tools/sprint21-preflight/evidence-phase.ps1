param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($module in @('owned-runtime.psm1','owned-phase-support.psm1')){Import-Module (Join-Path $c.workspace ('tools/sprint21/'+$module)) -Force -DisableNameChecking}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedPrivateDirectory $c.output
if([DateTimeOffset]$c.phase_deadline_utc -gt [DateTimeOffset]'2026-10-23T00:06:30Z'){throw 'stage_deadline'}
if($c.public_evidence -cne (Join-Path $c.workspace 'evidence/sprint21-preflight')){throw 'public_scope'}
function Run([string]$Label,[string[]]$Arguments,[int]$Seconds=60){
 $left=([DateTimeOffset]$c.phase_deadline_utc-[DateTimeOffset]::UtcNow).TotalSeconds
 if($left -lt 2){throw 'evidence_deadline'}
 [void](Invoke-OwnedPhaseCommand $c.python $c.python_sha (@('-I','-B','-X','utf8')+$Arguments) $c.workspace $c.output $Label @{} ([Math]::Min($Seconds,[int][Math]::Floor($left))) 4MB)
}
$tools=Join-Path $c.workspace 'tools/sprint21-preflight'
Run 'private-independent-audit' @((Join-Path $tools 'audit-controls.py'),$c.control_source,(Join-Path $c.output 'private-audit-proof.json'))
Run 'explicit-selection' @((Join-Path $tools 'select-evidence.py'),$c.workspace,$c.control_source,$c.selection_manifest,$c.evidence_attributes) 30
Run 'bounded-public-projection' @((Join-Path $c.workspace 'tools/sprint21/project-public-evidence.py'),'--workspace',$c.workspace,'--manifest',$c.selection_manifest,'--output',$c.public_evidence) 90
$manifest=Join-Path $c.public_evidence 'projection-manifest.json';$sha=Get-OwnedHash $manifest
Run 'all-public-package-bytes' @((Join-Path $tools 'verify-package.py'),$c.public_evidence,$sha,(Join-Path $c.output 'package-proof.json'))
Run 'public-independent-audit' @((Join-Path $tools 'audit-controls.py'),$c.public_evidence,(Join-Path $c.output 'public-audit-proof.json'),$manifest)
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'evidence-proof.json') @{status='PREFLIGHT_PRIVATE_AND_PUBLIC_SAVED_CONTROLS_AND_ALL_PACKAGE_BYTES_VERIFIED';projection_manifest_sha256=$sha;private_audit_sha256=Get-OwnedHash (Join-Path $c.output 'private-audit-proof.json');public_audit_sha256=Get-OwnedHash (Join-Path $c.output 'public-audit-proof.json');package_proof_sha256=Get-OwnedHash (Join-Path $c.output 'package-proof.json');feature_processes_started=$false;utc=[DateTimeOffset]::UtcNow.ToString('o')}
