param([Parameter(Mandatory)][string]$FixtureDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../tools/sprint15/full-lock2-stream-phase.ps1'
$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$errors)
if($errors.Count){throw 'stream_source_parse'}
foreach($name in @('CaptureFlags','CaptureHealthy','ReadClosedCaptureHash')){$f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object Name -ceq $name);if($f.Count -ne 1){throw 'stream_function_unique'};. ([scriptblock]::Create($f[0].Extent.Text))}
function Assert-OwnedNoReparse([string]$Path){if((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'test_reparse'}}
if(Test-Path -LiteralPath $FixtureDirectory){throw 'new_fixture_required'}
$null=New-Item -ItemType Directory -Path $FixtureDirectory
$base=Join-Path ([IO.Path]::GetFullPath($FixtureDirectory)) 'coordinator'
$cap=[pscustomobject]@{LimitReached=$false;ReadComplete=$true;Pump=[pscustomobject]@{IsFaulted=$false;IsCanceled=$false;IsCompleted=$true}}
$co=@{Base=$base;Process=[pscustomobject]@{HasExited=$true;ExitCode=-1};OutCapture=$cap;ErrCapture=$cap}
$service=@{Coordinator=$co};$bytes=[Text.Encoding]::UTF8.GetBytes('closed producer retained writer fixture')
$writer=[IO.File]::Open($base+'.stdout',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
$cases=0
function Reject([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};if(!$failed){throw 'expected_refusal_missing'};$script:cases++}
try{
 $writer.Write($bytes,0,$bytes.Length);$writer.Flush($true)
 $expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
 if((ReadClosedCaptureHash ($base+'.stdout') $bytes.Length) -cne $expected -or !$writer.CanWrite){throw 'retained_writer_hash_mismatch'};$cases++
 Reject {ReadClosedCaptureHash ($base+'.other') $bytes.Length}
 Reject {ReadClosedCaptureHash ($base+'.stdout') ($bytes.Length+1)}
 Reject {ReadClosedCaptureHash ($base+'.stdout') (4MB+1)}
 $cap.Pump.IsCompleted=$false;Reject {ReadClosedCaptureHash ($base+'.stdout') $bytes.Length};$cap.Pump.IsCompleted=$true
 $co.Process.HasExited=$false;Reject {ReadClosedCaptureHash ($base+'.stdout') $bytes.Length};$co.Process.HasExited=$true
 $co.Process.ExitCode=0;Reject {ReadClosedCaptureHash ($base+'.stdout') $bytes.Length};$co.Process.ExitCode=-1
 $cap.LimitReached=$true;Reject {ReadClosedCaptureHash ($base+'.stdout') $bytes.Length};$cap.LimitReached=$false
 $cap.ReadComplete=$false;Reject {ReadClosedCaptureHash ($base+'.stdout') $bytes.Length};$cap.ReadComplete=$true
 if($IsWindows){
  Reject {$r=[IO.File]::OpenRead($base+'.stdout');$r.Dispose()}
  Reject {$w=[IO.File]::Open($base+'.stdout',[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$w.Dispose()}
 }
 if((ReadClosedCaptureHash ($base+'.stdout') $bytes.Length) -cne $expected -or !$writer.CanWrite){throw 'writer_disposed_or_content_changed'};$cases++
}finally{$writer.Dispose()}
@{status='PASS';cases=$cases;windows_native_sharing=$IsWindows;fixture=$base+'.stdout';source_sha256=(Get-FileHash -LiteralPath $source).Hash}|ConvertTo-Json