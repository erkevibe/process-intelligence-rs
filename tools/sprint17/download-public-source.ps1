Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
$ws=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..')
$out=New-OwnedPrivateDirectory (Join-Path $ws '.local/sprint17/root/public-source01')
$url='https://codeload.github.com/erkevibe/process-intelligence-rs/zip/2660ede595fb37e9ff75613e562f8c08c8d4c6fd'
$handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false;$handler.UseDefaultCredentials=$false
$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(30)
$cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30));$response=$null;$input=$null;$output=$null
try{
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]'2026-10-21T13:00:01Z' -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'download_resource_deadline'}
 $response=$client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
 if([int]$response.StatusCode -ne 200 -or ($response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt 32MB)){throw 'public_source_http_bound'}
 $path=Join-Path $out 'core-source.zip';$output=[IO.File]::Open($path,'CreateNew','Write','Read');$input=$response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
 $buffer=[byte[]]::new(65536);$bytes=0L
 while(($n=$input.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0){$bytes+=$n;if($bytes -gt 32MB){throw 'public_source_size_bound'};$output.Write($buffer,0,$n)}
 $output.Flush($true);$output.Dispose();$output=$null
 Write-OwnedJson (Join-Path $out 'download.json') @{status='ANONYMOUS_SOURCE_DOWNLOADED_NOT_YET_VALIDATED';url=$url;bytes=$bytes;sha256=Get-OwnedHash $path;utc=[DateTimeOffset]::UtcNow.ToString('o');authentication_sent=$false;redirects_followed=$false;not_browser_or_localhost_action=$true}
}finally{if($output){$output.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()};$client.Dispose();$cancel.Dispose()}
