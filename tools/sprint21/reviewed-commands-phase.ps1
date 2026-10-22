param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
if($c.commands.Count -gt 8){throw 'command_count'}
$results=[Collections.Generic.List[object]]::new()
foreach($command in $c.commands){
 if($command.seconds -lt 1 -or $command.seconds -gt 600 -or $command.cap -gt 16MB){throw 'command_bound'}
 if([DateTimeOffset]::UtcNow.AddSeconds($command.seconds+15) -ge [DateTimeOffset]$c.phase_deadline_utc){throw 'command_deadline'}
 $results.Add((Invoke-OwnedPhaseCommand $command.program $command.sha256 ([string[]]$command.arguments) $command.directory $c.output $command.label @{} $command.seconds $command.cap))
}
$after=@()
if($c.ContainsKey('mutable_format_sources')){
 $after=@($c.mutable_format_sources|ForEach-Object{@{path=$_;sha256=Get-OwnedHash $_}})
}
Write-OwnedJson (Join-Path $c.output 'commands-proof.json') @{status='ACTUAL_REVIEWED_COMMANDS_NATIVE_ZERO';config_sha256=$PhaseConfigSha;commands=$results.ToArray();formatted_sources_after=$after;acceptance_not_claimed=$true}
