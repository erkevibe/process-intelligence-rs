param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha -or (Get-Item $PhaseConfig).Length -gt 1MB){throw 'public_config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in @(@('owned-runtime.psm1',$c.module_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if((Get-FileHash (Join-Path $PSScriptRoot $pin[0])).Hash -cne $pin[1]){throw 'public_preimport_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.scope -cne 's15-anonymous-public-core-package-readback' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C' -or $c.phase_reservation_bytes -ne 2GB -or $c.capture_reservation_bytes -ne 512MB -or $c.phase_budget.db_wal_temp_extract_archive_bytes -ne 1536MB){throw 'public_finite_scope'}
$budget=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started ([DateTime]::UtcNow)
# The generic 1536MiB install reservation is deliberately conservative artifact
# space here: no package extraction, application, PostgreSQL or service starts.
$assets=New-OwnedPrivateDirectory $c.install_parent
$out=Get-OwnedCanonicalPath $c.output_directory
function DownloadPublic([string]$Url,[string]$Name,[long]$Cap,[long]$ExpectedBytes=0){
 Assert-S14PhaseBudget -Proof $budget -Next $Cap
 $handler=[Net.Http.HttpClientHandler]::new();$handler.UseCookies=$false;$handler.AllowAutoRedirect=$true
 $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(120)
 $cts=[Threading.CancellationTokenSource]::new(120000);$response=$null;$input=$null;$writer=$null;$sha=$null
 try{
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('ProcessIntelligence-R3-public-readback')
  $response=$client.GetAsync($Url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).GetAwaiter().GetResult()
  if([int]$response.StatusCode -ne 200){throw 'public_http_not_200'}
  $final=$response.RequestMessage.RequestUri
  if($final.Scheme -cne 'https' -or $final.Host -cnotin @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com','codeload.github.com')){throw 'public_redirect_host'}
  $length=$response.Content.Headers.ContentLength;if($null -ne $length -and ($length -gt $Cap -or ($ExpectedBytes -gt 0 -and $length -ne $ExpectedBytes))){throw 'public_content_length'}
  $input=$response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
  $path=Join-Path $assets $Name;$writer=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $sha=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256);$buffer=[byte[]]::new(65536);$total=0L
  while($true){
   if([DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'public_freeze_or_floor'}
   $read=$input.ReadAsync($buffer,0,$buffer.Length,$cts.Token);if(!$read.Wait(15000)){$cts.Cancel();throw 'public_read_deadline'};$n=$read.GetAwaiter().GetResult();if($n -eq 0){break}
   $total+=$n;if($total -gt $Cap){throw 'public_download_cap'};$writer.Write($buffer,0,$n);$sha.AppendData($buffer,0,$n)
  }
  if($total -le 0 -or ($ExpectedBytes -gt 0 -and $total -ne $ExpectedBytes) -or ($null -ne $length -and $total -ne $length)){throw 'public_complete_length'}
  $writer.Flush($true);$digest=[Convert]::ToHexString($sha.GetHashAndReset())
  return @{requested_url=$Url;final_host=$final.Host;final_path=$final.AbsolutePath;http_status=200;anonymous_no_authorization_header=$true;cookies_disabled=$true;complete_eof=$true;bytes=$total;sha256=$digest;path=$path;utc=[DateTime]::UtcNow.ToString('o')}
 }finally{if($sha){$sha.Dispose()};if($writer){$writer.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()};$cts.Dispose();$client.Dispose();$handler.Dispose()}
}
$package=DownloadPublic 'https://github.com/erkevibe/process-intelligence-rs/releases/download/v0.7.3/process-intelligence-rs-0.7.3-windows-x86_64.zip' 'public-package.zip' 57505214 57505214
if($package.sha256 -cne $c.package_sha){throw 'public_actual_asset_sha'}
$source=DownloadPublic 'https://codeload.github.com/erkevibe/process-intelligence-rs/zip/3f0b3caa34b9b4beaf4422f78c2e31c0f97d3209' 'public-core-source.zip' 128MB
Write-OwnedJson (Join-Path $out 'anonymous-downloads.json') @{author_role='Root';package=$package;core_source=$source;scope=$c.scope;no_downloaded_executable_execution_claim=$true}
$report=Join-Path $assets 'full-readback.json'
$result=(& $c.validator -PackageZip $package.path -CoreSourceZip $source.path -GitPath $c.git -GitSha256 $c.git_sha -ReportPath $report)|ConvertFrom-Json -AsHashtable -DateKind String
if($result.status -cne 'OFFLINE_FULL_PACKAGE_AND_CORE_SOURCE_READBACK_VERIFIED' -or $result.package_sha256 -cne $c.package_sha -or $result.source_core_commit -cne '3f0b3caa34b9b4beaf4422f78c2e31c0f97d3209'){throw 'public_validator_result'}
[long]$assetBytes=0;foreach($f in Get-ChildItem -LiteralPath $assets -Force){Assert-OwnedNoReparse $f.FullName;if($f.PSIsContainer){throw 'public_flat_assets'};$assetBytes+=$f.Length}
if($assetBytes+16MB -gt 256MB){throw 'public_all_assets_fixed_reserve'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-S14PhaseBudget -Proof $budget
Write-OwnedJson (Join-Path $out 'public-readback-result.json') @{status='ACTUAL_ANONYMOUS_PACKAGE_AND_CORE_SOURCE_FULL_READBACK_PENDING_QA_TD';downloads=(Join-Path $out 'anonymous-downloads.json');validator_report=@{path=$report;sha256=Get-OwnedHash $report};public_assets_bytes=$assetBytes;public_metadata_screen_other_reserve_bytes=16MB;public_aggregate_cap_bytes=256MB;no_post_download_install_execution_claim=$true;runtime_composition='Separate accepted NEW canonical E798 PS7 publicStart/browser/restart; anonymous fullpublic sameE798 proves exactbyte identity';no_full_R3_claim=$true}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $budget)