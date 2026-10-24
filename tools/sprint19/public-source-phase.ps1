param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
if($c.public_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'exact_public_commit'}
Assert-OwnedPrivateDirectory $c.output
$expected=Join-Path $c.output 'expected-source.zip'
$git=Invoke-OwnedPhaseCommand $c.git $c.git_sha @('archive','--format=zip',('--output='+$expected),$c.public_commit) $c.workspace $c.output 'git-archive' @{GIT_TERMINAL_PROMPT='0'} 60 4MB
$url='https://codeload.github.com/erkevibe/process-intelligence-rs/zip/'+$c.public_commit
$handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false;$handler.UseDefaultCredentials=$false
$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(30)
$cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30));$response=$null;$input=$null;$output=$null
try{
 $response=$client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
 if([int]$response.StatusCode -ne 200 -or ($response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt 32MB)){throw 'public_source_http_bound'}
 $path=Join-Path $c.output 'public-source.zip';$output=[IO.File]::Open($path,'CreateNew','Write','Read');$input=$response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
 $buffer=[byte[]]::new(65536);$bytes=0L
 while(($n=$input.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0){$bytes+=$n;if($bytes -gt 32MB){throw 'public_source_size_bound'};$output.Write($buffer,0,$n)}
 $output.Flush($true);$output.Dispose();$output=$null
 Write-OwnedJson (Join-Path $c.output 'download.json') @{status='ACTUAL_ANONYMOUS_SOURCE_DOWNLOADED_NOT_YET_VALIDATED';url=$url;commit=$c.public_commit;bytes=$bytes;sha256=Get-OwnedHash $path;utc=[DateTimeOffset]::UtcNow.ToString('o');authentication_sent=$false;redirects_followed=$false;not_browser_or_localhost_action=$true}
}finally{if($output){$output.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()};$client.Dispose();$cancel.Dispose()}
$check=Invoke-OwnedPhaseCommand $c.public_python $c.public_python_sha @('-I','-B',$c.public_verifier,$expected,$path,$c.public_commit,(Join-Path $c.output 'readback.json')) $c.workspace $c.output 'verify-source' @{} 60 4MB
# Extract only after the complete safe regular-member inventory and every hash
# have matched the exact local Git archive. This never executes native engines.
$extracted=New-OwnedPrivateDirectory (Join-Path $c.output 'source')
[IO.Compression.ZipFile]::ExtractToDirectory($path,$extracted)
$publicRoot=Join-Path $extracted ('process-intelligence-rs-'+$c.public_commit)
Assert-OwnedNoReparse $publicRoot
foreach($name in @('bpmn-quality','miner-quality')){
 $r=Invoke-OwnedPhaseCommand $c.public_python $c.public_python_sha @('-I','-B',(Join-Path $publicRoot 'tools/sprint19/verify-quality-manifest.py'),(Join-Path $publicRoot ('evidence/sprint19/'+$name))) $publicRoot $c.output ('manifest-'+$name) @{} 60 4MB
}
foreach($name in @('calendar','filter-extended')){
 $r=Invoke-OwnedPhaseCommand $c.public_python $c.public_python_sha @('-I','-B',(Join-Path $publicRoot 'tools/sprint19/verify-core-projection.py'),(Join-Path $publicRoot ('evidence/sprint19/core-'+$name))) $publicRoot $c.output ('manifest-'+$name) @{} 60 4MB
 $r=Invoke-OwnedPhaseCommand $c.public_node $c.public_node_sha @((Join-Path $publicRoot ('tools/oracle/compare-core-'+$name+'.mjs')),(Join-Path $publicRoot ('evidence/sprint19/core-'+$name+'/java-index.json')),(Join-Path $publicRoot ('evidence/sprint19/core-'+$name+'/rust-index.json')),(Join-Path $c.output ($name+'-comparison.json'))) $publicRoot $c.output ('compare-'+$name) @{} 60 4MB
 $comparison=Get-Content -LiteralPath (Join-Path $c.output ($name+'-comparison.json')) -Raw|ConvertFrom-Json -AsHashtable
 if($comparison.status -cne 'ACTUAL_FINITE_COMPARISON_COMPLETED' -or @($comparison.cases|Where-Object{!$_.all_frozen_hypotheses_match}).Count){throw 'public_comparison_hypothesis_or_status'}
 if($comparison.case_count -ne $(if($name -ceq 'calendar'){13}else{8}) -or $comparison.cases.Count -ne $comparison.case_count){throw 'public_comparison_exact_case_count'}
 if($name -ceq 'calendar'){
  if(@($comparison.cases|Where-Object{$_.main_equality_eligible -and $_.main_overlap_fields_match -ne $true}).Count){throw 'public_calendar_complete_main_overlap_fields'}
 }elseif(@($comparison.cases|Where-Object{$_.profile -ceq 'overlap' -and $_.overlap_fields_match -ne $true}).Count){throw 'public_filter_complete_overlap_fields'}
}
$base=Join-Path $publicRoot 'evidence/sprint19/bpmn-quality'
$r=Invoke-OwnedPhaseCommand $c.public_python $c.public_python_sha @('-I','-B',(Join-Path $publicRoot 'tools/oracle/audit-quality-evidence.py'),'--rust',(Join-Path $base 'rust-metrics.json'),'--reference',(Join-Path $base 'reference-metrics.json'),'--prepared',(Join-Path $base 'prepared'),'--corpus',(Join-Path $publicRoot 'fixtures/quality/corpus.json'),'--output',(Join-Path $c.output 'base-audit.json')) $publicRoot $c.output 'base-audit' @{} 60 4MB
$miner=Join-Path $publicRoot 'evidence/sprint19/miner-quality'
$r=Invoke-OwnedPhaseCommand $c.public_python $c.public_python_sha @('-I','-B',(Join-Path $publicRoot 'tools/oracle/audit-quality-cohort.py'),'--corpus',(Join-Path $publicRoot 'fixtures/quality-miner/corpus.json'),'--prepared',(Join-Path $miner 'prepared'),'--conversion',(Join-Path $miner 'reference-conversion'),'--rust',(Join-Path $miner 'rust-metrics.json'),'--reference',(Join-Path $miner 'reference-metrics.json'),'--output',(Join-Path $c.output 'miner-audit.json')) $publicRoot $c.output 'miner-audit' @{} 60 4MB
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'public-replay-proof.json') @{status='ENTIRE_ANONYMOUS_PUBLIC_SOURCE_AND_ALL_FOUR_S19_EVIDENCE_REPLAYS_VERIFIED';commit=$c.public_commit;public_zip_sha256=Get-OwnedHash $path;readback_sha256=Get-OwnedHash (Join-Path $c.output 'readback.json');base_audit_sha256=Get-OwnedHash (Join-Path $c.output 'base-audit.json');miner_audit_sha256=Get-OwnedHash (Join-Path $c.output 'miner-audit.json');calendar_comparison_sha256=Get-OwnedHash (Join-Path $c.output 'calendar-comparison.json');filter_comparison_sha256=Get-OwnedHash (Join-Path $c.output 'filter-extended-comparison.json');no_native_engine_executed=$true}
