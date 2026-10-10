param([string]$BaseUrl='http://127.0.0.1:3000')
$ErrorActionPreference='Stop'
$results=[Collections.Generic.List[object]]::new()
function Observe([string]$name,[bool]$ok,[object]$detail) {
    $results.Add([pscustomobject]@{scenario=$name;passed=$ok;detail=$detail})
}
$health=Invoke-WebRequest "$BaseUrl/health" -SkipHttpErrorCheck
Observe 'health' ($health.StatusCode -eq 200) @{status=$health.StatusCode;body=$health.Content}
$demo=Invoke-WebRequest "$BaseUrl/demo" -Method Post -SkipHttpErrorCheck
Observe 'demo' ($demo.StatusCode -eq 200) @{status=$demo.StatusCode}
$id=[regex]::Match($demo.Content,'/logs/(log-\d+)/export').Groups[1].Value
if (!$id) {throw 'No exported log ID in demo HTML'}
$export=Invoke-RestMethod "$BaseUrl/logs/$id/export"
Observe 'manual-counts' ($export.analysis.cases -eq 4 -and $export.analysis.events -eq 10 -and $export.analysis.activities -eq 3) @{cases=$export.analysis.cases;events=$export.analysis.events;activities=$export.analysis.activities}
$csp=[string]$demo.Headers['Content-Security-Policy']
Observe 'csp-header' ($csp.Contains("connect-src 'self'") -and $csp.Contains("'nonce-") -and !$csp.Contains('unsafe-eval')) @{policy=$csp}
$view=Invoke-WebRequest "$BaseUrl/logs/$id/view" -Method Post -ContentType 'application/x-www-form-urlencoded' -Body 'threshold=2' -SkipHttpErrorCheck
$after=Invoke-RestMethod "$BaseUrl/logs/$id/export"
$sseLines=$view.Content -split "`n"
$rawHtml=@($sseLines | Where-Object {$_ -match '^<'})
Observe 'view-sse' ($view.StatusCode -eq 200 -and $view.Content.Contains('data: elements ') -and $rawHtml.Count -eq 0) @{status=$view.StatusCode;content_type=[string]$view.Headers['Content-Type'];raw_html_lines=$rawHtml.Count}
Observe 'view-export-agreement' ($after.view.min_edge_frequency -eq 2 -and $after.view.edges.Count -eq 2 -and $after.view.nodes.Count -eq 3 -and $after.analysis.events -eq 10) @{threshold=$after.view.min_edge_frequency;edges=$after.view.edges.Count;nodes=$after.view.nodes.Count;revision=$after.view.view_revision}
$badFile=Get-Item (Join-Path $PSScriptRoot '..\fixtures\invalid-malformed.xes')
$bad=Invoke-WebRequest "$BaseUrl/logs" -Method Post -Form @{file=$badFile} -SkipHttpErrorCheck
$preserved=Invoke-RestMethod "$BaseUrl/logs/$id/export"
Observe 'invalid-preserves-previous' ($bad.StatusCode -eq 422 -and (($preserved | ConvertTo-Json -Depth 30 -Compress) -eq ($after | ConvertTo-Json -Depth 30 -Compress)) -and $bad.Content.Contains($id)) @{status=$bad.StatusCode;log_id=$id}
$invalid=Invoke-WebRequest "$BaseUrl/logs/$id/selection" -Method Post -ContentType 'application/x-www-form-urlencoded' -Body 'kind=edge&id=missing' -SkipHttpErrorCheck
Observe 'invalid-selection' ($invalid.StatusCode -eq 400) @{status=$invalid.StatusCode}
$foreign=Invoke-WebRequest "$BaseUrl/demo" -Method Post -Headers @{Origin='https://attacker.example'} -SkipHttpErrorCheck
Observe 'cross-origin' ($foreign.StatusCode -eq 403) @{status=$foreign.StatusCode}
$result=[pscustomobject]@{run_id='sprint-01';observer='qa_process';time_utc=[DateTime]::UtcNow.ToString('o');scope='live HTTP; in-process tests remain separate STOP scope; no browser claims';log_id=$id;results=$results}
$destination=Join-Path $PSScriptRoot '..\flw\evidence\qa-live-http.json'
$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $destination -Encoding utf8
$result | ConvertTo-Json -Depth 30
