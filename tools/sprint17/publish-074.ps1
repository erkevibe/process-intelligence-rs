param([Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$RequestSha256,[Parameter(Mandatory)][string]$AcceptancePath,[Parameter(Mandatory)][string]$AcceptanceSha256,[Parameter(Mandatory)][string]$CheckpointPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ws=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
$scope=Join-Path $ws '.local/sprint17/root/completion01/'
foreach($path in @($RequestPath,$AcceptancePath,$CheckpointPath)){
 if(!([IO.Path]::GetFullPath($path)).StartsWith($scope,[StringComparison]::OrdinalIgnoreCase)){throw 'publication_private_scope'}
 Assert-OwnedPrivateDirectory (Split-Path -Parent ([IO.Path]::GetFullPath($path)))
}
Assert-OwnedHash $RequestPath $RequestSha256;Assert-OwnedHash $AcceptancePath $AcceptanceSha256
if(Test-Path -LiteralPath $CheckpointPath){throw 'new_publication_checkpoint_required'}
$req=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$accept=Get-Content -LiteralPath $AcceptancePath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$core='2660ede595fb37e9ff75613e562f8c08c8d4c6fd'
$zip=Join-Path $ws '.local/sprint16/root/package02/candidate01/process-intelligence-rs-0.7.4-windows-x86_64.zip'
$zipSha='862427638D49AB02513184C0069DD13A6E7876D7EA023E511D4A3E1359E83D79'
Assert-OwnedHash $zip $zipSha
if((Get-Item -LiteralPath $zip).Length -ne 57780524 -or $req.tag_name -cne 'v0.7.4' -or $req.target_commitish -cne $core -or !$req.draft -or !$req.prerelease -or $req.diagnostic_head -cnotmatch '^[0-9a-f]{40}$'){throw 'publication_candidate_identity'}
if($accept.status -cne 'ACCEPTED_FOR_IMMUTABLE_PUBLICATION_WITH_POSTDELIVERY_GATES' -or $accept.proposal_sha256 -cne $req.acceptance_proposal_sha256 -or $accept.fixed_voters -ne 5){throw 'publication_acceptance_resolution'}
$actual=@();$roles=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$votePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$agents=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
if($accept.votes.Count -gt 5){throw 'publication_vote_count'}
foreach($entry in $accept.votes){
 if($entry.role -cnotin @('Root','QA','TD','PM','Customer')){throw 'publication_vote_role'}
 $folder=@{Root='root';QA='qa';TD='td';PM='pm';Customer='customer'}[$entry.role]
 $votePath=[IO.Path]::GetFullPath($entry.path)
 $voteScope=Join-Path $ws ('.local/sprint17/'+$folder+'/completion01/')
 if(!$votePath.StartsWith($voteScope,[StringComparison]::OrdinalIgnoreCase) -or !$votePaths.Add($votePath) -or (Get-Item -LiteralPath $votePath).Length -gt 65536){throw 'publication_vote_path_identity'}
 Assert-OwnedNoReparse $votePath
 Assert-OwnedHash $entry.path $entry.sha256
 $v=Get-Content -LiteralPath $entry.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($v.proposal_sha256 -cne $accept.proposal_sha256 -or $v.role -cne $entry.role -or !$v.agent -or $v.agent -cne $entry.agent -or !$agents.Add($v.agent) -or !$roles.Add($entry.role)){throw 'publication_vote_binding'}
 if($v.vote -ceq 'FOR'){$actual+=$entry.role}
}
if($actual.Count -lt 3 -or $actual -cnotcontains 'QA' -or $actual -cnotcontains 'TD'){throw 'publication_independent_votes_missing'}
Assert-OwnedHash $accept.proposal_path $accept.proposal_sha256
foreach($input in $accept.inputs){Assert-OwnedHash $input.path $input.sha256}
function Api([string]$Method,[string]$Uri,$Body=$null,[string]$File=$null){
 $u=[Uri]$Uri;if($u.Scheme -cne 'https' -or $u.Host -cnotin @('api.github.com','uploads.github.com') -or !$u.AbsolutePath.StartsWith('/repos/erkevibe/process-intelligence-rs/')){throw 'github_exact_destination'}
 $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false;$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(180)
 $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$Uri);$message.Headers.UserAgent.ParseAdd('ProcessIntelligence-S15');$message.Headers.Accept.ParseAdd('application/vnd.github+json')
 if($script:accessToken){$message.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$script:accessToken)}
 $stream=$null;$response=$null;$reader=$null;$store=[IO.MemoryStream]::new();$cts=[Threading.CancellationTokenSource]::new(180000)
 try{
  if($File){$stream=[IO.File]::OpenRead($File);$message.Content=[Net.Http.StreamContent]::new($stream);$message.Content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('application/zip');$message.Content.Headers.ContentLength=$stream.Length}
  elseif($null -ne $Body){$message.Content=[Net.Http.StringContent]::new(($Body|ConvertTo-Json -Depth 20),[Text.Encoding]::UTF8,'application/json')}
  $response=$client.SendAsync($message,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).GetAwaiter().GetResult()
  if(!$response.IsSuccessStatusCode){throw ('github_http_'+[int]$response.StatusCode)}
  $reader=$response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult();$buffer=[byte[]]::new(16384);$bytes=0L
  while($true){$t=$reader.ReadAsync($buffer,0,$buffer.Length,$cts.Token);if(!$t.Wait(10000)){$cts.Cancel();throw 'github_response_timeout'};$n=$t.GetAwaiter().GetResult();if(!$n){break};$bytes+=$n;if($bytes -gt 1MB){throw 'github_response_cap'};$store.Write($buffer,0,$n)}
  return ([Text.UTF8Encoding]::new($false,$true).GetString($store.ToArray())|ConvertFrom-Json -AsHashtable -DateKind String)
 }finally{if($reader){$reader.Dispose()};if($response){$response.Dispose()};$message.Dispose();if($stream){$stream.Dispose()};$store.Dispose();$cts.Dispose();$client.Dispose();$handler.Dispose()}
}
function GitHubToken {
 $git='C:\Program Files\Git\cmd\git.exe';if((Get-FileHash $git).Hash -cne '78211C7ED73988DA93A6D8A33D47EC6187F464D7EA2A9A00C182BBD7A1ECF30F'){throw 'credential_git_pin'}
 $si=[Diagnostics.ProcessStartInfo]::new();$si.FileName=$git;$si.WorkingDirectory=[string]$PWD;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
 $si.Environment['GIT_TERMINAL_PROMPT']='0';$si.Environment['GCM_INTERACTIVE']='never';$si.ArgumentList.Add('credential');$si.ArgumentList.Add('fill')
 $p=[Diagnostics.Process]::new();$p.StartInfo=$si;$caps=@();$started=$false
 try{
  if(!$p.Start()){throw 'credential_process'};$started=$true;$p.StandardInput.Write("protocol=https`nhost=github.com`n`n");$p.StandardInput.Close()
  foreach($pipe in @($p.StandardOutput.BaseStream,$p.StandardError.BaseStream)){$b=[byte[]]::new(4096);$caps+=@{stream=$pipe;buffer=$b;store=[IO.MemoryStream]::new();bytes=0;eof=$false;pending=$pipe.ReadAsync($b,0,$b.Length)}}
  $until=[DateTime]::UtcNow.AddSeconds(10)
  while($true){if([DateTime]::UtcNow -ge $until){throw 'credential_timeout'};foreach($c in $caps){if(!$c.eof -and $c.pending.IsCompleted){if($c.pending.IsFaulted -or $c.pending.IsCanceled){throw 'credential_capture'};$n=$c.pending.GetAwaiter().GetResult();if(!$n){$c.eof=$true}else{$c.bytes+=$n;if($c.bytes -gt 16384){throw 'credential_cap'};$c.store.Write($c.buffer,0,$n);$c.pending=$c.stream.ReadAsync($c.buffer,0,$c.buffer.Length)}}};if($p.HasExited -and @($caps|Where-Object {!$_.eof}).Count -eq 0){break};[Threading.Thread]::Sleep(5)}
  if($p.ExitCode -ne 0){throw 'credential_unavailable'}
  $text=[Text.UTF8Encoding]::new($false,$true).GetString($caps[0].store.ToArray());$lines=@(($text -split "`n")|ForEach-Object {$_.TrimEnd([char]13)});$password=@($lines|Where-Object {$_ -cmatch '^password=.{16,2048}\r?$'})
  if($password.Count -ne 1 -or !($lines -ccontains 'host=github.com') -or !($lines -ccontains 'protocol=https')){throw 'credential_exact_host'}
  return $password[0].Substring(9).TrimEnd([char]13)
 }finally{if($started -and !$p.HasExited){$p.Kill($true);if(!$p.WaitForExit(2000)){throw 'credential_owned_stop'}};foreach($c in $caps){$c.stream.Dispose();$c.store.Dispose()};$p.Dispose()}
}
$script:accessToken=$null
try{
 $ci=Api 'GET' ('https://api.github.com/repos/erkevibe/process-intelligence-rs/actions/runs?head_sha='+$req.diagnostic_head+'&per_page=10')
 $runs=@()
 foreach($event in @('push','pull_request')){
  $matches=@($ci.workflow_runs|Where-Object {$_.event -ceq $event -and $_.head_sha -ceq $req.diagnostic_head -and $_.workflow_id -eq 380293369 -and $_.path -ceq '.github/workflows/ci.yml' -and $_.head_branch -ceq 'codex/sprint-16' -and $_.name -ceq 'Rust contract checks'})
  if($matches.Count -ne 1 -or $matches[0].status -cne 'completed' -or $matches[0].conclusion -cne 'success'){throw 'publication_exact_HEAD_CI_pending_or_failed'}
  $jobs=Api 'GET' ('https://api.github.com/repos/erkevibe/process-intelligence-rs/actions/runs/'+$matches[0].id+'/jobs?per_page=30')
  if($jobs.total_count -lt 1 -or $jobs.total_count -ne $jobs.jobs.Count -or @($jobs.jobs|Where-Object {$_.status -cne 'completed' -or $_.conclusion -cne 'success'}).Count){throw 'publication_CI_jobs_not_success'}
  foreach($job in $jobs.jobs){if($job.steps.Count -lt 1 -or @($job.steps|Where-Object {$_.status -cne 'completed' -or $_.conclusion -cne 'success'}).Count){throw 'publication_CI_steps_not_success'}}
  $runs+=@{id=$matches[0].id;event=$event;head_sha=$req.diagnostic_head;conclusion='success';jobs=@($jobs.jobs|ForEach-Object {@{id=$_.id;steps=$_.steps.Count}})}
 }
 $script:accessToken=GitHubToken
 $tagBefore=$null;try{$tagBefore=Api 'GET' 'https://api.github.com/repos/erkevibe/process-intelligence-rs/git/ref/tags/v0.7.4'}catch{if($_.Exception.Message -cne 'github_http_404'){throw}}
 if($tagBefore){$tagCommit=$tagBefore.object.sha;if($tagBefore.object.type -ceq 'tag'){$obj=Api 'GET' ('https://api.github.com/repos/erkevibe/process-intelligence-rs/git/tags/'+$tagCommit);$tagCommit=$obj.object.sha};if($tagCommit -cne $core){throw 'existing_tag_no_overwrite'}}
 $body=@{};foreach($key in @('tag_name','target_commitish','name','body','draft','prerelease')){$body[$key]=$req[$key]};$body.make_latest='false'
 $all=Api 'GET' 'https://api.github.com/repos/erkevibe/process-intelligence-rs/releases?per_page=100'
 $existing=@($all|Where-Object {$_.tag_name -ceq 'v0.7.4'})
 if($existing.Count -gt 1){throw 'release_ambiguous'}
 if($existing.Count){$rel=$existing[0];if($rel.target_commitish -cne $core -or $rel.name -cne $req.name -or $rel.body.Replace("`r`n","`n") -cne $req.body.Replace("`r`n","`n")){throw 'existing_release_request_mismatch_no_overwrite'}}else{$rel=Api 'POST' 'https://api.github.com/repos/erkevibe/process-intelligence-rs/releases' $body}
 if(!$rel.prerelease){throw 'existing_release_not_prerelease'}
 $assetName='process-intelligence-rs-0.7.4-windows-x86_64.zip';$matching=@($rel.assets|Where-Object {$_.name -ceq $assetName})
 if($matching.Count -gt 1){throw 'asset_ambiguous'}
 if($matching.Count){$asset=$matching[0]}else{$asset=Api 'POST' ('https://uploads.github.com/repos/erkevibe/process-intelligence-rs/releases/'+$rel.id+'/assets?name='+$assetName) $null $zip}
 if($asset.size -ne 57780524 -or $asset.state -cne 'uploaded' -or !$asset.ContainsKey('digest') -or !$asset.digest -or $asset.digest.ToUpperInvariant() -cne ('SHA256:'+$zipSha)){throw 'asset_digest_binding'}
 if($rel.draft){$rel=Api 'PATCH' ('https://api.github.com/repos/erkevibe/process-intelligence-rs/releases/'+$rel.id) @{draft=$false;prerelease=$true;make_latest='false'}}
 $tag=Api 'GET' 'https://api.github.com/repos/erkevibe/process-intelligence-rs/git/ref/tags/v0.7.4';$commit=$tag.object.sha
 if($tag.object.type -ceq 'tag'){$obj=Api 'GET' ('https://api.github.com/repos/erkevibe/process-intelligence-rs/git/tags/'+$commit);$commit=$obj.object.sha}
 if($commit -cne $core -or $rel.draft -or !$rel.prerelease){throw 'published_identity'}
 Write-OwnedJson $CheckpointPath @{status='PRERELEASE_PUBLISHED_POSTDELIVERY_READBACK_PENDING';utc=[DateTimeOffset]::UtcNow.ToString('o');release_id=$rel.id;release_url=$rel.html_url;asset_id=$asset.id;asset_url=$asset.browser_download_url;asset_bytes=$asset.size;asset_sha256=$zipSha;tag_commit=$commit;diagnostic_head=$req.diagnostic_head;ci=$runs;request_sha256=$RequestSha256;acceptance_sha256=$AcceptanceSha256;credentials_persisted_or_printed=$false;not_final_delivery_acceptance=$true}
}finally{$script:accessToken=$null}
