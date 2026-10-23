param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$f=Get-Item -LiteralPath $InputPath
if($f.Length -gt 4MB){throw 'Input exceeds accepted report cap'}
$before=(Get-FileHash -LiteralPath $InputPath -Algorithm SHA256).Hash
$stream=[IO.File]::OpenRead($f.FullName)
try {$doc=[Text.Json.JsonDocument]::Parse($stream,[Text.Json.JsonDocumentOptions]::new())}finally{$stream.Dispose()}
try {
 $rows=@();$top=0L;$evidenceChildren=0L
 foreach($p in $doc.RootElement.EnumerateObject()){
  $n=[Text.Encoding]::UTF8.GetByteCount($p.Value.GetRawText());$top+=$n
  $rows+=@{path=$p.Name;raw_value_utf8_bytes=$n}
  if($p.Name -eq 'evidence'){
   foreach($child in $p.Value.EnumerateObject()){
    $v=[Text.Encoding]::UTF8.GetByteCount($child.Value.GetRawText());$evidenceChildren+=$v
    $rows+=@{path='evidence.'+$child.Name;raw_value_utf8_bytes=$v}
   }
   $evidenceOverhead=$n-$evidenceChildren
  }
 }
 $after=(Get-FileHash -LiteralPath $InputPath -Algorithm SHA256).Hash
 if($before -ne $after){throw 'Input changed'}
 $result=[ordered]@{method='Original JSON value slices; UTF8 byte counts; top-level and evidence children overlap and must not be summed together';input_sha256=$before;input_bytes=$f.Length;top_value_bytes=$top;top_keys_punctuation_whitespace_bytes=$f.Length-$top;evidence_child_value_bytes=$evidenceChildren;evidence_keys_punctuation_whitespace_bytes=$evidenceOverhead;rows=$rows}
 $json=$result|ConvertTo-Json -Depth 8
 $output=[IO.FileStream]::new($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes($json);$output.Write($bytes)}finally{$output.Dispose()}
}finally{$doc.Dispose()}
