param([Parameter(Mandatory)][ValidateSet('before','roundtrip','after')][string]$Phase,[Parameter(Mandatory)][string]$Credentials,[Parameter(Mandatory)][string]$CredentialsSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
$ws=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..')
Assert-OwnedHash $Credentials $CredentialsSha
if((Get-OwnedCanonicalPath $Credentials) -cne (Join-Path $ws '.local/sprint17/root/http-credentials01.json')){throw 'credentials_scope'}
$out=New-OwnedPrivateDirectory (Join-Path $ws ('.local/sprint17/root/http-'+$Phase+'01'))
$pwsh='C:/Users/alikh/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$pwshSha='362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$node='C:/Program Files/nodejs/node.exe'
$nodeSha='BA93F9A70BD86FCE3EBBB39EC758501458453467AA92A34A0A3602D1E3FC2B9C'
$script=Join-Path $PSScriptRoot 'http-saved-roundtrip.mjs'
$worker=Join-Path $PSScriptRoot 'owned-process-worker.ps1'
$c=@{program=$node;program_sha256=$nodeSha;cwd=$ws;output_directory=$out;arguments=@($script,$Credentials,$Phase);environment=@{};max_output_bytes=1MB;module_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'owned-runtime.psm1');worker_sha256=Get-OwnedHash $worker;pwsh_sha256=$pwshSha;inputs=@(@{path=$script;sha256=Get-OwnedHash $script},@{path=$Credentials;sha256=$CredentialsSha})}
$config=Join-Path $out 'config.json';Write-OwnedJson $config $c;$hash=Get-OwnedHash $config
$job=[PiOwnedJob]::new();$child=$null;$done=$false;$reason=''
try{
 $child=Start-OwnedCapturedProcess -Program $pwsh -ProgramSha256 $pwshSha -Arguments @('-NoProfile','-File',$worker,'-ConfigPath',$config,'-ConfigSha256',$hash) -WorkingDirectory $ws -OutputDirectory $out -Label coordinator -MaxOutputBytes 1MB -RedirectInput $true
 $job.Assign($child.Handle);if(!$job.Member($child.Handle)){throw 'http_job_assignment'}
 Write-OwnedJson (Join-Path $out 'admission.json') @{exact_job=$true;pid=$child.Process.Id;creation_utc=$child.Record.native_creation_utc;config_sha256=$hash;phase=$Phase}
 $child.Process.StandardInput.WriteLine('GO '+$hash);$child.Process.StandardInput.Close();$end=[DateTimeOffset]::UtcNow.AddSeconds(60)
 while(!$child.Process.WaitForExit(100)){
  if([DateTimeOffset]::UtcNow -gt $end -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]'2026-10-21T13:00:01Z'){$reason='http_deadline'}
  if([IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){$reason='http_free_floor'}
  if($child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){$reason='http_capture'}
  if($reason){$job.Stop();if(!$child.Process.WaitForExit(10000)){throw 'http_stop_timeout'};break}
 }
 $r=Complete-OwnedCapturedProcess $child;$done=$true
 if($reason -or $r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'http_probe_failed'}
 Write-OwnedJson (Join-Path $out 'result.json') @{status='NATIVE_HTTP_PROBE_CLOSED';native_exit=$r.native_exit;phase=$Phase;config_sha256=$hash;browser_claim=$false}
}finally{if($child -and !$done){$job.Stop();if($child.Process.WaitForExit(10000)){[void](Complete-OwnedCapturedProcess $child)}};$job.Dispose()}
