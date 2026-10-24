param([Parameter(Mandatory)][string]$Directory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $workspace 'tools/sprint20/owned-runtime.psm1') -Force -DisableNameChecking
$out=New-OwnedPrivateDirectory $Directory
$source=Join-Path $workspace 'tools/sprint20/miner-benchmark-phase.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'protocol_source_parse'}
$definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-Protocol'},$true))
if($definitions.Count -ne 1){throw 'actual_protocol_function_identity'}
# Execute only the exact pinned pure reader definition, never the phase body.
. ([ScriptBlock]::Create($definitions[0].Extent.Text))
$path=Join-Path $out 'partial.stdout'
$writer=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try{
 $prefix=[Text.Encoding]::UTF8.GetBytes('warning ')
 $writer.Write($prefix);$writer.WriteByte(0xCE);$writer.Flush($true)
 if($null -ne (Read-Protocol $path 'BOOT_READY')){throw 'partial_codepoint_not_ignored'}
 $writer.WriteByte(0xB2);$writer.WriteByte(10)
 $record=[Text.Encoding]::UTF8.GetBytes('S20_PROTOCOL {"phase":"BOOT_READY","pid":123,"nonce":"control"}')
 $writer.Write($record);$writer.Flush($true)
 if($null -ne (Read-Protocol $path 'BOOT_READY')){throw 'partial_line_not_ignored'}
 $writer.WriteByte(10);$writer.Flush($true)
 $actual=Read-Protocol $path 'BOOT_READY'
 if($actual.pid -ne 123 -or $actual.nonce -cne 'control'){throw 'complete_record_changed'}
 if($null -ne (Read-Protocol $path 'TERMINAL_READY')){throw 'wrong_phase_accepted'}
}finally{$writer.Dispose()}
$invalid=Join-Path $out 'invalid.stdout'
[IO.File]::WriteAllBytes($invalid,[byte[]]@(255,10))
$rejected=$false
try{[void](Read-Protocol $invalid 'BOOT_READY')}catch{$rejected=$true}
if(!$rejected){throw 'invalid_complete_utf8_accepted'}
$large=Join-Path $out 'large.stdout'
[IO.File]::WriteAllBytes($large,[byte[]]::new(8MB+1))
$bounded=$false
try{[void](Read-Protocol $large 'BOOT_READY')}catch{$bounded=$_.Exception.Message -ceq 'protocol_stream_bound'}
if(!$bounded){throw 'protocol_cap_not_enforced'}
Write-OwnedJson (Join-Path $out 'result.json') @{status='PASS';actual_reader_source_sha256=Get-OwnedHash $source;checks=@('partial_utf8_wait','partial_line_wait','complete_identity','phase_separation','invalid_complete_utf8_refusal','8MiB_cap_refusal');not_engine_execution=$true}
