param([Parameter(Mandatory)][string]$Node,[Parameter(Mandatory)][string]$NodeSha,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../tools/owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $Node $NodeSha
Assert-OwnedPrivateDirectory $Output
& $Node -e 'process.stdout.write("NATIVE_BEFORE_STDOUT\n");process.stderr.write("NATIVE_BEFORE_STDERR\n")'
if($LASTEXITCODE -ne 0){throw 'direct_native_before_failed'}
# Start-Process uses direct files as in the packaged pg_ctl launcher. The long-lived
# descendant must not inherit the wrapper's separate original capture pipe.
$p=Start-Process -FilePath $Node -ArgumentList @('-e','"setTimeout(()=>{},60000)"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Output 'holder.stdout') -RedirectStandardError (Join-Path $Output 'holder.stderr')
$handle=$p.Handle
Write-OwnedJson (Join-Path $Output 'holder-start.json') @{pid=$p.Id;creation_utc=$p.StartTime.ToUniversalTime().ToString('o');image_sha256=$NodeSha}
Write-Output ('OWNED_HOLDER '+$p.Id)
$p.Dispose()
& $Node -e 'process.stdout.write("NATIVE_AFTER_STDOUT\n");process.stderr.write("NATIVE_AFTER_STDERR\n")'
if($LASTEXITCODE -ne 0){throw 'direct_native_after_failed'}
