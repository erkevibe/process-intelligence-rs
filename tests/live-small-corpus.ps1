param([string]$BaseUrl='http://127.0.0.1:3001',[string]$SourceSha,[string]$OutputFile=(Join-Path $PSScriptRoot '..\flw\evidence\qa-clean-small-corpus.json'))
$ErrorActionPreference='Stop'
$results=[Collections.Generic.List[object]]::new()
$fixtureRoot=Join-Path $PSScriptRoot '..\fixtures'
foreach($valid in @(@{name='manual.xes';cases=4;events=10;activities=3},@{name='semantics.xes';cases=4;events=4;activities=3})) {
 $file=Get-Item (Join-Path $fixtureRoot $valid.name)
 $response=Invoke-WebRequest "$BaseUrl/logs" -Method Post -Form @{file=$file} -SkipHttpErrorCheck
 $id=[regex]::Match($response.Content,'/logs/(log-\d+)/export').Groups[1].Value
 $before=Invoke-RestMethod "$BaseUrl/logs/$id/export"
 $results.Add([pscustomobject]@{fixture=$valid.name;status=$response.StatusCode;passed=($response.StatusCode -eq 200 -and $before.analysis.cases -eq $valid.cases -and $before.analysis.events -eq $valid.events -and $before.analysis.activities -eq $valid.activities);fixture_sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash})
 foreach($file in Get-ChildItem -LiteralPath $fixtureRoot -Filter 'invalid-*.xes') {
  $bad=Invoke-WebRequest "$BaseUrl/logs" -Method Post -Form @{file=$file} -SkipHttpErrorCheck
  $after=Invoke-RestMethod "$BaseUrl/logs/$id/export"
  $unchanged=($before|ConvertTo-Json -Depth 30 -Compress) -eq ($after|ConvertTo-Json -Depth 30 -Compress)
  $results.Add([pscustomobject]@{prior_valid=$valid.name;fixture=$file.Name;status=$bad.StatusCode;previous_unchanged=$unchanged;passed=($bad.StatusCode -eq 422 -and $unchanged);fixture_sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash})
 }
}
[pscustomobject]@{source_sha=$SourceSha;observer='qa_process';time_utc=[DateTime]::UtcNow.ToString('o');results=$results} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputFile -Encoding utf8
$results | Select-Object fixture,status,passed | Format-Table -AutoSize
