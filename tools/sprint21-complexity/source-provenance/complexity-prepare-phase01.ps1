param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY DRAFT. No input generation is authorized until the separately
# reviewed CAP delivery gate and a fresh fixed-five Council authorize this stage.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'complexity_prepare_config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $c.workspace 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
if(!$c.ContainsKey('execution_authorized_by_fresh_council') -or $c.execution_authorized_by_fresh_council -ne $true){throw 'complexity_draft_execution_not_admitted'}
Assert-OwnedHash $c.cap_gate_receipt $c.cap_gate_receipt_sha;Assert-OwnedHash $c.fresh_council_receipt $c.fresh_council_receipt_sha
$stageStart=[DateTimeOffset]::Parse([string]$c.stage_started_utc,[Globalization.CultureInfo]::InvariantCulture)
$gate=[DateTimeOffset]::Parse([string]$c.cap_gate_completed_utc,[Globalization.CultureInfo]::InvariantCulture)
if($gate -gt [DateTimeOffset]'2026-10-22T22:30:00Z' -or $stageStart -lt $gate -or [DateTimeOffset]::UtcNow -lt $stageStart){throw 'complexity_fresh_stage_entry_gate'}
$nativeEnd=$stageStart.AddMinutes(20);$freeze=[DateTimeOffset]'2026-10-23T00:30:37Z';if($nativeEnd -gt $freeze){$nativeEnd=$freeze}
$prepareEnd=[DateTimeOffset]::UtcNow.AddSeconds(25);if($prepareEnd -gt $nativeEnd){$prepareEnd=$nativeEnd}
$root=Join-Path $c.workspace '.local/sprint21/root'
if($c.output -cne (Join-Path $root 'complexity-prepare01') -or $c.input_directory -cne (Join-Path $root 'complexity-inputs01')){throw 'complexity_prepare_exact_scope'}
Assert-OwnedPrivateDirectory $c.output
if($c.app_sha -cne '4121BD68F1C0C05A61B039FADF20FEC5C2DA4379D8AAAFB170DC3B43861D1525'){throw 'complexity_immutable_app_identity'}
Assert-OwnedHash $c.app $c.app_sha
if(Test-Path -LiteralPath $c.input_directory){throw 'complexity_input_directory_must_be_fresh'}
$inputs=New-OwnedPrivateDirectory $c.input_directory
$utf8=[Text.UTF8Encoding]::new($false)
$timestamp='2026-01-01T00:00:00.000000001Z'
$head='<log xes.version="1.0" xmlns="http://www.xes-standard.org/"><trace><string key="concept:name" value="complexity-case"/>'+"`n"
$event='<event><string key="concept:name" value="A"/><date key="time:timestamp" value="2026-01-01T00:00:00.000000001Z"/></event>'+"`n"
$tail="</trace></log>`n"
$csvHead="case,activity,timestamp,lifecycle`n";$csvRow="complexity-case,A,$timestamp,`n"
$eventBlock=$utf8.GetBytes((($event*256)-join ''));$csvBlock=$utf8.GetBytes((($csvRow*256)-join ''))
$cases=[Collections.Generic.List[object]]::new()
function Bounds {if([DateTimeOffset]::UtcNow -ge $prepareEnd -or [DateTimeOffset]::UtcNow -ge $nativeEnd -or (Get-PSDrive C).Free -lt 8GB){throw 'complexity_prepare_time_or_free_floor'}}
try{
 foreach($spec in @(@{id='CMP10K';events=10000},@{id='CMP90K';events=90000})){
  Bounds
  $count=[int]$spec.events
  [long]$expectedBytes=$utf8.GetByteCount($head)+[long]$count*$utf8.GetByteCount($event)+$utf8.GetByteCount($tail)
  [long]$expectedCsvBytes=$utf8.GetByteCount($csvHead)+[long]$count*$utf8.GetByteCount($csvRow)
  if($count -gt 100000 -or $expectedBytes -gt 20MB -or $expectedCsvBytes -gt 20MB){throw 'complexity_static_preflight_bound_requires_replan_before_observation'}
  $inputName=$spec.id+'.xes';$csvName=$spec.id+'.expected-lf.csv';$oracleName=$spec.id+'-oracle.json'
  $input=Join-Path $inputs $inputName;$manualCsv=Join-Path $inputs $csvName
  $xes=[IO.File]::Open($input,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  $csv=[IO.File]::Open($manualCsv,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{
   $bytes=$utf8.GetBytes($head);$xes.Write($bytes,0,$bytes.Length);$bytes=$utf8.GetBytes($csvHead);$csv.Write($bytes,0,$bytes.Length)
   $remaining=$count
   while($remaining -ge 256){Bounds;$xes.Write($eventBlock,0,$eventBlock.Length);$csv.Write($csvBlock,0,$csvBlock.Length);$remaining-=256}
   if($remaining){$bytes=$utf8.GetBytes((($event*$remaining)-join ''));$xes.Write($bytes,0,$bytes.Length);$bytes=$utf8.GetBytes((($csvRow*$remaining)-join ''));$csv.Write($bytes,0,$bytes.Length)}
   $bytes=$utf8.GetBytes($tail);$xes.Write($bytes,0,$bytes.Length);$xes.Flush($true);$csv.Flush($true)
  }finally{$xes.Dispose();$csv.Dispose()}
  if((Get-Item -LiteralPath $input).Length -ne $expectedBytes -or (Get-Item -LiteralPath $manualCsv).Length -ne $expectedCsvBytes){throw 'complexity_generated_length_mismatch'}
  $oracle=@{case_id=$spec.id;trace_count=1;event_count=$count;trace_name='complexity-case';activity='A';timestamp=$timestamp;lifecycle=$null;allowed_loss_count=0;expected_csv_header=@('case','activity','timestamp','lifecycle');expected_csv_row=@('complexity-case','A',$timestamp,'');manual_csv_normalization='UTF8 CSV parsed rows; canonical LF header/rows supplied for independent normalization only; candidate raw serialization NOT preasserted';row_order_scope='identical repeated values; count/field conservation, not ordering sensitivity or activity diversity';manual_csv_file=$csvName;manual_csv_sha256=Get-OwnedHash $manualCsv;manual_csv_bytes=$expectedCsvBytes}
  Write-OwnedJson (Join-Path $inputs $oracleName) $oracle
  $cases.Add(@{id=$spec.id;events=$count;trace_count=1;input_file=$inputName;input_bytes=$expectedBytes;input_sha256=Get-OwnedHash $input;oracle_file=$oracleName;oracle_sha256=Get-OwnedHash (Join-Path $inputs $oracleName);manual_csv_file=$csvName;manual_csv_bytes=$expectedCsvBytes;manual_csv_sha256=Get-OwnedHash $manualCsv})
 }
 Bounds
 $manifest=@{schema_version=1;status='PROSPECTIVE_INPUTS_FROZEN_BEFORE_MEASUREMENT';app_sha256=$c.app_sha;generator_source_sha256=Get-OwnedHash $PSCommandPath;config_sha256=$PhaseConfigSha;deterministic_utf8_lf_no_bom=$true;no_converter_invoked=$true;cases=$cases.ToArray();scope='Two fixed repeated-event count/field observations; not graph complexity, ordering sensitivity, diversity or worst case.';utc=[DateTimeOffset]::UtcNow.ToString('o')}
 Write-OwnedJson (Join-Path $inputs 'manifest.json') $manifest
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 Write-OwnedJson (Join-Path $c.output 'input-generation-proof.json') @{status='ACTUAL_FIXED_INPUT_GENERATION_BEFORE_MEASUREMENTS';input_manifest_sha256=Get-OwnedHash (Join-Path $inputs 'manifest.json');generator_source_sha256=Get-OwnedHash $PSCommandPath;app_sha256=$c.app_sha;event_counts=@(10000,90000);converter_executed=$false;measurements_performed=$false;static_byte_event_bounds_verified=$true}
}catch{
 $primary=$_;try{Write-OwnedJson (Join-Path $c.output 'private-failure.json') @{exception_type=$primary.Exception.GetType().FullName;message=$primary.Exception.Message;position=$primary.InvocationInfo.PositionMessage;script_stack_trace=$primary.ScriptStackTrace;actual_generated_case_receipts=$cases.ToArray()}}catch{Write-Warning ('complexity_prepare_failure_receipt_diagnostic: '+$_.Exception.Message)};throw $primary
}
