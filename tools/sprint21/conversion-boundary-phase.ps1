param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.sha256){throw 'input_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output
$inputs=New-OwnedPrivateDirectory (Join-Path $c.output 'inputs')
$cases=New-OwnedPrivateDirectory (Join-Path $c.output 'cases')
$rows=[Collections.Generic.List[object]]::new()
$utf8=[Text.UTF8Encoding]::new($false)
$external=Join-Path $inputs 'external.csv'
[IO.File]::WriteAllText($external,('case,activity,timestamp,lifecycle'+"`r`n"+'case-external,"Review, café",2026-10-22T00:00:00.000000001Z,complete'+"`r`n"),$utf8)
$spaces=Join-Path $inputs 'whitespace.csv'
[IO.File]::WriteAllText($spaces,('case,activity,timestamp,lifecycle'+"`r`n"+'one,   ,,'+"`r`n"),$utf8)
$oversized=Join-Path $inputs 'oversized.csv'
$s=[IO.File]::Open($oversized,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
try{$s.SetLength(20MB+1);$s.Flush($true)}finally{$s.Dispose()}
$existing=New-OwnedPrivateDirectory (Join-Path $cases 'existing-output')
$marker=Join-Path $existing 'keep.txt';[IO.File]::WriteAllText($marker,'must remain unchanged',$utf8);$markerHash=Get-OwnedHash $marker
function Rel([string]$Path){[IO.Path]::GetRelativePath($c.output,$Path).Replace('\','/')}
function Probe([string]$Id,[string]$From,[string]$To,[string]$InputPath,[string]$OutputPath,[int]$ExpectedExit,[object]$Expected,[bool]$Allow=$false){
 if([DateTimeOffset]::UtcNow.AddSeconds(45) -ge [DateTimeOffset]$c.phase_deadline_utc){throw 'boundary_deadline'}
 $capture=New-OwnedPrivateDirectory (Join-Path $cases ($Id+'-capture'))
 $arguments=@($From,$To,$InputPath,$OutputPath);if($Allow){$arguments+='--allow-metadata-loss'}
 $child=Start-OwnedCapturedProcess -Program $c.converter -ProgramSha256 $c.converter_sha -Arguments $arguments -WorkingDirectory $c.workspace -OutputDirectory $capture -Label converter -MaxOutputBytes 4MB -Environment @{RAYON_NUM_THREADS='1'}
 $end=[DateTimeOffset]::UtcNow.AddSeconds(30);$stopped=$false
 while(!$child.Process.WaitForExit(100)){
  if([DateTimeOffset]::UtcNow -ge $end -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted){$stopped=$true;$child.Process.Kill($true);if(!$child.Process.WaitForExit(10000)){throw 'boundary_stop_failed'};break}
 }
 $native=Complete-OwnedCapturedProcess $child
 $files=@()
 if(Test-Path -LiteralPath $OutputPath -PathType Container){$files=@(Get-ChildItem -LiteralPath $OutputPath -File -Force|Sort-Object Name|ForEach-Object{@{path=$_.Name;bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})}
 $rows.Add(@{id=$Id;from=$From;to=$To;input_path=Rel $InputPath;output_directory=Rel $OutputPath;allow_metadata_loss=$Allow;expected_exit=$ExpectedExit;expected=$Expected;native_exit=$native.native_exit;native_record_path=Rel ($child.Base+'.process.json');files=$files;timed_out_or_capture_stopped=$stopped})
}
$core=@{traces=@(@{name='case-external';events=@(@{activity='Review, café';timestamp='2026-10-22T00:00:00.000000001Z';lifecycle='complete'})})}
$sourceHash=Get-OwnedHash $external
Probe 'B01' 'csv' 'xes' $external (Join-Path $cases 'novel-xes') 0 @{status='converted';core=$core;no_fixture_lookup=$true}
Probe 'B02' 'xes' 'csv' (Join-Path $cases 'novel-xes/payload.xes') (Join-Path $cases 'novel-csv') 0 @{status='converted';core=$core;exact_csv_sha256=$sourceHash;separate_actual_inverse=$true}
Probe 'B03' 'csv' 'xes' $external $existing 1 @{unchanged_marker_sha256=$markerHash;only_file='keep.txt'}
Probe 'B04' 'csv' 'xes' $oversized (Join-Path $cases 'oversized-result') 1 @{no_output_directory=$true;input_bytes=20MB+1}
Probe 'B05' 'csv' 'xes' (Join-Path $inputs 'absent.csv') (Join-Path $cases 'missing-result') 1 @{no_output_directory=$true}
Probe 'B06' 'csv' 'xes' $inputs (Join-Path $cases 'directory-result') 1 @{no_output_directory=$true}
Probe 'B07' 'csv' 'xes' $external (Join-Path $cases 'absent-parent/result') 1 @{no_output_directory=$true;no_parent_created=$true}
Probe 'B08' 'csv' 'xes' $spaces (Join-Path $cases 'whitespace-default') 2 @{status='refused';reason='production_xes_parser_refused';only_report=$true}
Probe 'B09' 'csv' 'xes' $spaces (Join-Path $cases 'whitespace-allow') 2 @{status='refused';reason='production_xes_parser_refused';only_report=$true} $true
Assert-OwnedHash $external $sourceHash;Assert-OwnedHash $marker $markerHash
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Write-OwnedJson (Join-Path $c.output 'index.json') @{schema_version=1;converter_sha256=$c.converter_sha;cases=$rows.ToArray();external_input_sha256=$sourceHash;inputs_unchanged=$true;scope='Additional independently specified external-file/boundary observations; not part of the frozen57 and not self-asserted acceptance'}
