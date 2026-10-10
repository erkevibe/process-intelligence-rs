param(
 [string]$BaseUrl='http://127.0.0.1:3000',
 [string]$GeneratedDirectory=(Join-Path $PSScriptRoot '..\.local\qa-generated'),
 [string]$OutputDirectory=(Join-Path $PSScriptRoot '..\.local\qa-admission'),
 [string]$PublicSummary=(Join-Path $PSScriptRoot '..\flw\evidence\qa-admission.json'),
 [string]$PidFile=(Join-Path $PSScriptRoot '..\.local\app.pid')
)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$results=[Collections.Generic.List[object]]::new()
function CurrentExport([string]$html) {
 $id=[regex]::Match($html,'/logs/(log-\d+)/export').Groups[1].Value
 if (!$id) {throw 'No previous analysis ID found'}
 return Invoke-RestMethod "$BaseUrl/logs/$id/export"
}
$cases=@(
 @{name='bytes-20971520.xes';status=200;cases=0;events=0;activities=0},
 @{name='bytes-20971521.xes';status=413},
 @{name='events-100000.xes';status=200;cases=1;events=100000;activities=1},
 @{name='events-100001.xes';status=422},
 @{name='cases-20000.xes';status=200;cases=20000;events=0;activities=0},
 @{name='cases-20001.xes';status=422},
 @{name='activity-ascii-4096.xes';status=200;cases=1;events=1;activities=1},
 @{name='activity-ascii-4097.xes';status=422},
 @{name='activity-unicode-4096.xes';status=200;cases=1;events=1;activities=1},
 @{name='activity-unicode-4097.xes';status=422},
 @{name='benchmark-10k.xes';status=200;cases=1000;events=10000;activities=20}
)
foreach ($case in $cases) {
 $previousPage=Invoke-WebRequest "$BaseUrl/" -SkipHttpErrorCheck
 $previous=CurrentExport $previousPage.Content
 $file=Get-Item (Join-Path $GeneratedDirectory $case.name)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 $response=Invoke-WebRequest "$BaseUrl/logs" -Method Post -Form @{file=$file} -TimeoutSec 300 -SkipHttpErrorCheck
 $clock.Stop()
 # Raw response is synthetic but remains private, along with request/result metadata.
 [IO.File]::WriteAllText((Join-Path $OutputDirectory ($case.name+'.response.html')),$response.Content)
 $actual=CurrentExport $response.Content
 $matches=$response.StatusCode -eq $case.status
 if ($case.status -eq 200) {
  $countsOk=$actual.analysis.cases -eq $case.cases -and $actual.analysis.events -eq $case.events -and $actual.analysis.activities -eq $case.activities
  $matches=$matches -and $countsOk
 } else {
  $countsOk=($actual | ConvertTo-Json -Depth 30 -Compress) -eq ($previous | ConvertTo-Json -Depth 30 -Compress)
  $matches=$matches -and $countsOk
 }
 $peak=$null
 if (Test-Path -LiteralPath $PidFile) {
  $processNumber=[int](Get-Content -LiteralPath $PidFile -Raw)
  $process=Get-Process -Id $processNumber -ErrorAction SilentlyContinue
  if ($process) {$process.Refresh();$peak=$process.PeakWorkingSet64}
 }
 $row=[pscustomobject]@{fixture=$case.name;fixture_sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;bytes=$file.Length;expected_status=$case.status;actual_status=$response.StatusCode;passed=$matches;counts_or_previous_unchanged=$countsOk;cases=$actual.analysis.cases;events=$actual.analysis.events;activities=$actual.analysis.activities;http_upload_wall_ms=$clock.Elapsed.TotalMilliseconds;server_parse_analysis_ms=$actual.elapsed_ms;process_lifetime_peak_working_set_bytes=$peak}
 $results.Add($row);$row | ConvertTo-Json -Depth 5
}
$summary=[pscustomobject]@{run_id='sprint-01';observer='qa_process';time_utc=[DateTime]::UtcNow.ToString('o');profile='debug live server; not release';measurement_limits='HTTP wall includes multipart transport/render; server elapsed_ms reports parse+analysis; RSS is process-lifetime peak working set, not precise per-job peak';results=$results}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PublicSummary -Encoding utf8
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'full-results.json') -Encoding utf8
