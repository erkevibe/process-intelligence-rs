param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
$manifest=Get-Content -LiteralPath $c.corpus -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$inputs=New-OwnedPrivateDirectory (Join-Path $c.output 'inputs')
$caseRoot=New-OwnedPrivateDirectory (Join-Path $c.output 'cases')
$rows=[Collections.Generic.List[object]]::new()
function Relative([string]$Path){return [IO.Path]::GetRelativePath($c.output,$Path).Replace('\','/')}
function Run-Conversion([string]$From,[string]$To,[string]$InputPath,[string]$Directory,[string]$Capture,[bool]$AllowLoss){
 $arguments=@($From,$To,$InputPath,$Directory)
 if($AllowLoss){$arguments+='--allow-metadata-loss'}
 if([DateTimeOffset]::UtcNow.AddSeconds(45) -ge [DateTimeOffset]$c.phase_deadline_utc){throw 'conversion_launch_deadline'}
 $child=Start-OwnedCapturedProcess -Program $c.converter -ProgramSha256 $c.converter_sha -Arguments $arguments -WorkingDirectory $c.workspace -OutputDirectory $Capture -Label converter -MaxOutputBytes 4MB -Environment @{RAYON_NUM_THREADS='1'}
 $deadline=[DateTimeOffset]::UtcNow.AddSeconds(30);$stopped=$false
 try{
  while(!$child.Process.WaitForExit(100)){
   if([DateTimeOffset]::UtcNow -ge $deadline -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){$stopped=$true;$child.Process.Kill($true);if(!$child.Process.WaitForExit(10000)){throw 'converter_stop_timeout'};break}
  }
  $native=Complete-OwnedCapturedProcess $child
 }catch{if(!$child.Process.HasExited){$child.Process.Kill($true);[void]$child.Process.WaitForExit(10000)};throw}
 $report=Join-Path $Directory 'report.json'
 $reportHash=if(Test-Path -LiteralPath $report){Get-OwnedHash $report}else{$null}
 return @{input_path=Relative $InputPath;output_directory=Relative $Directory;report_sha256=$reportHash;native_record_path=Relative ($child.Base+'.process.json');timed_out_or_capture_stopped=$stopped;native_exit=$native.native_exit}
}
foreach($case in $manifest.cases){
 if($case.id -cnotmatch '^[A-Z][0-9]{2,3}$' -or $case.input -cnotmatch '^[A-Za-z0-9._-]+$'){throw 'case_path_identity'}
 $inputSource=Join-Path (Split-Path -Parent $c.corpus) $case.input
 Assert-OwnedNoReparse $inputSource;Assert-OwnedHash $inputSource $case.input_sha256
 if((Get-Item -LiteralPath $inputSource).Length -ne $case.input_bytes){throw 'case_input_size'}
 $inputCopy=Join-Path $inputs $case.input
 if(!(Test-Path -LiteralPath $inputCopy)){[IO.File]::Copy($inputSource,$inputCopy,$false)}
 Assert-OwnedHash $inputCopy $case.input_sha256
 $caseDir=New-OwnedPrivateDirectory (Join-Path $caseRoot $case.id)
 $capture=New-OwnedPrivateDirectory (Join-Path $caseDir 'capture-forward')
 $forwardDir=Join-Path $caseDir 'forward'
 $forward=Run-Conversion $case.from $case.to $inputCopy $forwardDir $capture ([bool]$case.allow_metadata_loss)
 $inverse=$null
 if($case.expected.requires_separate_actual_inverse -and (Test-Path -LiteralPath (Join-Path $forwardDir 'report.json'))){
  $report=Get-Content -LiteralPath (Join-Path $forwardDir 'report.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
  if($report.status -ceq 'converted'){
   $extension=@{'xes'='xes';'csv'='csv';'petri-json'='json';'pnml'='pnml'}[$case.to]
   $payload=Join-Path $forwardDir ('payload.'+$extension)
   Assert-OwnedNoReparse $payload
   $inverseCapture=New-OwnedPrivateDirectory (Join-Path $caseDir 'capture-inverse')
   $inverse=Run-Conversion $case.to $case.from $payload (Join-Path $caseDir 'inverse') $inverseCapture $false
  }
 }
 $rows.Add(@{id=$case.id;forward=$forward;inverse=$inverse})
 Write-OwnedJson (Join-Path $c.output ('checkpoint-'+$case.id+'.json')) @{cases=$rows.ToArray();scope='Actual completed calls only; not independent acceptance'}
}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'index.json') @{schema_version=1;corpus_sha256=Get-OwnedHash $c.corpus;method_sha256=$manifest.method_sha256;converter_sha256=$c.converter_sha;cases=$rows.ToArray();scope='Actual CLI calls and separate inverse calls, complete native records; expected matching is independently audited, not asserted here'}
