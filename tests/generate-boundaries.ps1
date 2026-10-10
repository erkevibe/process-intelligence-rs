param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\fixtures\generated'))
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
function Save-Xes([string]$name, [string]$content) {
    [IO.File]::WriteAllText((Join-Path $OutputDirectory $name), $content, $utf8)
}
function Event([string]$activity) {
    return '<event><string key="concept:name" value="' + $activity + '"/></event>'
}
foreach ($n in 100000,100001) {
    $body = [Text.StringBuilder]::new('<log><trace>')
    for ($i=0; $i -lt $n; $i++) { [void]$body.Append((Event 'A')) }
    [void]$body.Append('</trace></log>')
    Save-Xes "events-$n.xes" $body.ToString()
}
foreach ($n in 20000,20001) {
    Save-Xes "cases-$n.xes" ('<log>' + ('<trace/>' * $n) + '</log>')
}
foreach ($n in 4096,4097) {
    Save-Xes "activity-ascii-$n.xes" ('<log><trace>' + (Event ('A' * $n)) + '</trace></log>')
    # U+049A is two UTF-8 bytes; fill odd final byte with ASCII.
    $label = ('Қ' * [int][Math]::Floor($n/2)) + ('A' * ($n % 2))
    Save-Xes "activity-unicode-$n.xes" ('<log><trace>' + (Event $label) + '</trace></log>')
}
foreach ($n in 20971520,20971521) {
    $prefix = '<log><!--'
    $suffix = '--></log>'
    Save-Xes "bytes-$n.xes" ($prefix + ('x' * ($n-$prefix.Length-$suffix.Length)) + $suffix)
}
$benchmark = [Text.StringBuilder]::new('<log>')
for ($case=0; $case -lt 1000; $case++) {
    [void]$benchmark.Append('<trace>')
    for ($event=0; $event -lt 10; $event++) {
        [void]$benchmark.Append((Event ('Activity' + (($case+$event)%20))))
    }
    [void]$benchmark.Append('</trace>')
}
[void]$benchmark.Append('</log>')
Save-Xes 'benchmark-10k.xes' $benchmark.ToString()
Get-ChildItem -LiteralPath $OutputDirectory -File | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash
