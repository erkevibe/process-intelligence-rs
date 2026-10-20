[CmdletBinding(DefaultParameterSetName='Run')]
param(
 [Parameter(Mandatory,ParameterSetName='Run')][string]$ConfigPath,
 [Parameter(Mandatory,ParameterSetName='Run')][string]$ConfigSha256,
 [Parameter(Mandatory,ParameterSetName='Run')][string]$QaProof,
 [Parameter(Mandatory,ParameterSetName='Run')][string]$QaProofSha256,
 [Parameter(Mandatory,ParameterSetName='Run')][string]$TdProof,
 [Parameter(Mandatory,ParameterSetName='Run')][string]$TdProofSha256,
 [Parameter(Mandatory,ParameterSetName='SelfTest')][switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-S14LaunchDeadline([string]$Text,[DateTime]$Now) {
 if($Text -cnotmatch '^2026-10-20T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'){throw 'launcher_deadline_literal_utc_required'}
 $d=[DateTimeOffset]::ParseExact($Text,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
 $freeze=[DateTimeOffset]::ParseExact('2026-10-20T09:54:16Z',"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
 if($d -gt $freeze -or $Now -ge $d){throw 'launcher_expired_or_extended_deadline'}
 return $d
}
if($SelfTest){
 $now=[DateTimeOffset]::Parse('2026-10-20T03:24:16Z').UtcDateTime;$checks=0
 $decoded='{"deadline_utc":"2026-10-20T09:54:16Z"}'|ConvertFrom-Json -AsHashtable -DateKind String
 if($decoded.deadline_utc -isnot [string]){throw 'deadline_json_type'}
 if((Get-S14LaunchDeadline $decoded.deadline_utc $now).Kind -ne [DateTimeKind]::Utc){throw 'deadline_kind'};$checks++
 foreach($bad in @('10/20/2026 09:54:16','2026-10-20T11:24:16Z','2026-10-19T19:44:42Z','2026-10-20T03:24:16Z','2026-10-20T03:00:00Z','2026-10-20T09:54:16+05:00','2026-10-20T99:54:16Z','')){
  $refused=$false;try{[void](Get-S14LaunchDeadline $bad $now)}catch{$refused=$true};if(!$refused){throw 'deadline_negative_failed'};$checks++
 }
 @{status='S14_LAUNCH_DEADLINE_REGRESSION_PASSED';checks=$checks;scope='Pure date/JSON parsing only; no imports, files, children, PG or phase execution'}|ConvertTo-Json -Compress
 exit 0
}
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$privatePrefix=[IO.Path]::GetFullPath((Join-Path $workspace '.local/sprint14')).TrimEnd('\')+'\'
function Read-S14LaunchJson([string]$Path,[string]$Sha){
 $p=[IO.Path]::GetFullPath($Path)
 if(!$p.StartsWith($privatePrefix,[StringComparison]::OrdinalIgnoreCase) -or $Sha -cnotmatch '^[A-F0-9]{64}$' -or (Get-Item -LiteralPath $p).Length -gt 1MB -or (Get-FileHash -LiteralPath $p).Hash -cne $Sha){throw 'launcher_pinned_private_json'}
 return Get-Content -LiteralPath $p -Raw|ConvertFrom-Json -AsHashtable -DateKind String
}
$c=Read-S14LaunchJson $ConfigPath $ConfigSha256
if($c.deadline_utc -isnot [string]){throw 'launcher_deadline_type'}
[void](Get-S14LaunchDeadline $c.deadline_utc ([DateTime]::UtcNow))
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'launcher_floor_and_free'}
foreach($pair in @(@('QA',$QaProof,$QaProofSha256),@('TD',$TdProof,$TdProofSha256))){
 $r=Read-S14LaunchJson $pair[1] $pair[2]
 if($r.author_role -cne $pair[0] -or $r.config_sha256 -cne $ConfigSha256 -or $r.verdict -cnotmatch '(^|_)GO($|_)' -or $r.verdict -cmatch 'HOLD|STOP|REJECT'){throw 'launcher_exact_independent_GO'}
}
foreach($pin in @(@($c.program,$c.program_sha256),@((Join-Path $PSScriptRoot 'owned-runtime.psm1'),$c.module_sha256),@((Join-Path $PSScriptRoot 'owned-process-worker.ps1'),$c.worker_sha256),@((Join-Path $PSScriptRoot 'run-owned-process.ps1'),$c.supervisor_sha256))){
 if((Get-FileHash -LiteralPath $pin[0]).Hash -cne $pin[1]){throw 'launcher_source_tool_pin'}
}
foreach($pin in $c.inputs){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'launcher_input_pin'}}
$pwsh=(Get-Process -Id $PID).Path
if((Get-FileHash -LiteralPath $pwsh).Hash -cne $c.pwsh_sha256){throw 'launcher_interpreter_pin'}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $ConfigPath $ConfigSha256
$inputDirectory=Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
foreach($p in @($inputDirectory,$c.output_directory)){Assert-OwnedPrivateDirectory $p}
foreach($p in @($QaProof,$TdProof)){Assert-OwnedNoReparse $p;Assert-OwnedPrivateDirectory (Split-Path -Parent $p)}
if(@(Get-ChildItem -LiteralPath $c.output_directory -Force).Count){throw 'launcher_requires_new_empty_output'}
[void](Get-S14LaunchDeadline $c.deadline_utc ([DateTime]::UtcNow))
Write-OwnedJson (Join-Path $inputDirectory 'root-invocation01.json') @{utc=[DateTime]::UtcNow.ToString('o');config_sha256=$ConfigSha256;launcher_sha256=Get-OwnedHash $PSCommandPath;QA_sha256=$QaProofSha256;TD_sha256=$TdProofSha256;date_parser='DateKindString+exactUTC+terminatingerrors';fresh_private_empty_output=$true}
& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run-owned-process.ps1') -ConfigPath ([IO.Path]::GetFullPath($ConfigPath)) -ConfigSha256 $ConfigSha256 1> (Join-Path $inputDirectory 'launcher.stdout') 2> (Join-Path $inputDirectory 'launcher.stderr')
$native=$LASTEXITCODE
Write-OwnedJson (Join-Path $inputDirectory 'root-launch-result01.json') @{native_exit=$native;utc=[DateTime]::UtcNow.ToString('o');stdout_sha256=Get-OwnedHash (Join-Path $inputDirectory 'launcher.stdout');stderr_sha256=Get-OwnedHash (Join-Path $inputDirectory 'launcher.stderr');complete_native_parent_return=$true}
@{status='S14_ROOT_LAUNCH_RETURNED';native_exit=$native;config_sha256=$ConfigSha256}|ConvertTo-Json -Compress
exit $native
