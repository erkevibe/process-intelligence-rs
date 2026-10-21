param([Parameter(Mandatory)][string]$Script,[Parameter(Mandatory)][string]$ScriptSha,[Parameter(Mandatory)][string]$Proof,[string]$ArgumentsJson='{}')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $Script $ScriptSha
Assert-OwnedNoReparse $Script
Assert-OwnedPrivateDirectory (Split-Path -Parent $Proof)
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class PiStdioInheritance {
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetHandleInformation(IntPtr h,out uint f);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr h,uint m,uint f);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetFileType(IntPtr h);
 public static uint[] Clear(int n){var h=GetStdHandle(n);uint before,after;if(h==IntPtr.Zero||h==new IntPtr(-1)||!GetHandleInformation(h,out before))throw new Exception("stdio_handle");uint type=GetFileType(h);if(!SetHandleInformation(h,1,0)||!GetHandleInformation(h,out after)||(after&1)!=0)throw new Exception("stdio_inheritance_clear");return new uint[]{type,before,after};}
 public static uint Restore(int n,uint before){var h=GetStdHandle(n);uint after;if(!SetHandleInformation(h,1,before&1)||!GetHandleInformation(h,out after)||(after&1)!=(before&1))throw new Exception("stdio_inheritance_restore");return after;}
}
'@
$scriptParameters=ConvertFrom-Json -InputObject $ArgumentsJson -AsHashtable -DateKind String
if($ArgumentsJson.Length -gt 65536 -or $scriptParameters -isnot [hashtable] -or $scriptParameters.Count -gt 16){throw 'stdio_script_arguments'}
$script:stdioLaunchCount=0
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath,[string[]]$ArgumentList,[ValidateSet('Hidden')][string]$WindowStyle,[switch]$PassThru,[string]$RedirectStandardOutput,[string]$RedirectStandardError)
    if (-not $RedirectStandardOutput -or -not $RedirectStandardError) { throw 'stdio_requires_both_redirects' }
    $script:stdioLaunchCount++
    $launchProof=if($script:stdioLaunchCount -eq 1){$Proof}else{$Proof+'.launch'+$script:stdioLaunchCount+'.json'}
    $handles=@()
    try {
        foreach($number in @(-11,-12)){$v=[PiStdioInheritance]::Clear($number);$handles+=@{standard_handle=$number;file_type=$v[0];flags_before=$v[1];flags_after=$v[2];inherit_cleared=$true}}
        Write-OwnedJson $launchProof @{utc=[DateTime]::UtcNow.ToString('o');pid=$PID;script_sha256=$ScriptSha;handles=$handles;scope='Own capture pipes noninheritable only during explicitly redirected Start-Process; original handles remain open'}
        Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
    } finally {
        $restored=@()
        foreach($entry in $handles){$after=[PiStdioInheritance]::Restore($entry.standard_handle,[uint32]$entry.flags_before);$restored+=@{standard_handle=$entry.standard_handle;flags_restored=$after;flags_original=$entry.flags_before}}
        Write-OwnedJson ($launchProof+'.restored.json') @{utc=[DateTime]::UtcNow.ToString('o');pid=$PID;handles=$restored;scope='Restore original own standard-handle inheritance before subsequent direct native commands'}
    }
}
& $Script @scriptParameters
if($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0){exit $LASTEXITCODE}
