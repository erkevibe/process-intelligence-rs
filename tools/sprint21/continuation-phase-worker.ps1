param([Parameter(Mandatory)][string]$Config,[Parameter(Mandatory)][string]$ConfigSha,[Parameter(Mandatory)][string]$Nonce)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$line=[Console]::In.ReadLineAsync()
if(!$line.Wait(30000) -or $line.Result -cne ('GO '+$Nonce)){throw 'owned_job_go'}
if((Get-FileHash -LiteralPath $Config).Hash -cne $ConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$phaseDeadline=[DateTimeOffset]'2026-10-23T00:30:37Z'
if($c.ContainsKey('phase_deadline_utc')){
 $requestedDeadline=[DateTimeOffset]::ParseExact([string]$c.phase_deadline_utc,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
 if($requestedDeadline -gt $phaseDeadline){throw 'deadline_extension_refused'}
 $phaseDeadline=$requestedDeadline
}
if([DateTimeOffset]::UtcNow -ge $phaseDeadline){throw 'phase_deadline_expired'}
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Set-Location -LiteralPath $c.workspace
$env:RUSTUP_HOME=$c.rustup_home;$env:RUSTUP_TOOLCHAIN='1.99.0-x86_64-pc-windows-gnu';$env:CARGO_HOME=$c.cargo_home;$env:CARGO_TARGET_DIR=$c.target;$env:CARGO_INCREMENTAL='0';$env:CARGO_PROFILE_RELEASE_DEBUG='0';$env:CARGO_BUILD_JOBS='2';$env:TEMP=$c.temp;$env:TMP=$c.temp
$env:CARGO_PROFILE_DEV_DEBUG='0';$env:CARGO_PROFILE_TEST_DEBUG='0'
$env:PATH=$c.toolchain_bin+';'+$c.linker_self+';'+$c.linker_bin+';'+$env:PATH
$sep=[char]0x1f;$env:CARGO_ENCODED_RUSTFLAGS="-C${sep}dlltool=$($c.dlltool)${sep}-C${sep}linker=$($c.linker)${sep}-C${sep}linker-flavor=ld.lld${sep}-C${sep}link-self-contained=yes"
if([DateTimeOffset]::UtcNow -ge $phaseDeadline){throw 'runtime_freeze'}
& $c.phase -PhaseConfig $Config -PhaseConfigSha $ConfigSha
exit 0
