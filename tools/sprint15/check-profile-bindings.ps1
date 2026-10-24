param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha,[Parameter(Mandatory)][string]$PhaseScript)
# Read-only static admission. No import, child process, database or output mutation.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function AssertFile([string]$Path,[long]$Cap=1MB){$f=Get-Item -LiteralPath $Path;if($f.PSIsContainer -or $f.Attributes -band [IO.FileAttributes]::ReparsePoint -or $f.Length -gt $Cap){throw 'profile_regular_bounded_file_required'}}
AssertFile $PhaseConfig;AssertFile $PhaseScript 2MB
if($PhaseConfigSha -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'profile_config_sha_mismatch'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$source=(Get-FileHash -LiteralPath $PhaseScript).Hash
if($c.phase_budget.phase_sha -cne $source){throw 'profile_actual_source_binding_mismatch'}
AssertFile $c.phase_budget.capture_allowlist.path
if((Get-FileHash -LiteralPath $c.phase_budget.capture_allowlist.path).Hash -cne $c.phase_budget.capture_allowlist.sha256){throw 'profile_allowlist_file_sha_mismatch'}
$allow=Get-Content -LiteralPath $c.phase_budget.capture_allowlist.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($allow.phase_sha256 -cne $source -or $allow.scope -cne $c.scope){throw 'profile_allowlist_source_or_scope_mismatch'}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($p in $allow.relative_paths){if($p -isnot [string] -or !$seen.Add($p) -or [IO.Path]::IsPathRooted($p) -or $p -match '(^|[\\/])\.\.([\\/]|$)'){throw 'profile_literal_unique_capture_path_required'}}
if($seen.Count -lt 1 -or $seen.Count -gt 10000){throw 'profile_capture_path_count'}
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'profile_input_sha_mismatch'}}
@{status='STATIC_PHASE_SOURCE_ALLOWLIST_BINDINGS_VERIFIED';scope=$c.scope;phase_sha256=$source;config_sha256=$PhaseConfigSha.ToUpperInvariant();capture_paths=$seen.Count;pins=@($c.pins).Count;limits=@('Static source/hash/scope binding only; no independent semantic approval or actual readiness','Fresh native storage admission, private ACLs, Job/PID/ports, deadlines and full runtime results remain mandatory')}|ConvertTo-Json -Depth 4 -Compress
