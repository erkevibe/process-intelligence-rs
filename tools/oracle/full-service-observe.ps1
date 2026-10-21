param(
 [Parameter(Mandatory)][string]$ClasspathPath,
 [Parameter(Mandatory)][string]$BuildProofPath,
 [Parameter(Mandatory)][string]$OutputPath,
 [string]$CorpusPath='',
 [string]$CorpusSha256='3AF07E2094ABD0A91CB6BBBE0E152DC9341CA40E75C3B238B6DB1EC0B30ABF60'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$own=Join-Path $workspace '.local/sprint16/service'
$output=[IO.Path]::GetFullPath($OutputPath)
if(!$output.StartsWith($own+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'new_private_observer_scope'}
Import-Module (Join-Path $PSScriptRoot 'full-service-runtime.psm1') -Force -DisableNameChecking
[void](New-OwnedPrivateDirectory $output)
$proof=Get-Content $BuildProofPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($proof.original_source_files -ne 5763){throw 'complete_original_source_proof'}
foreach($f in $proof.runtime_files){Assert-OwnedHash $f.path $f.sha256}
if((Get-FileHash $ClasspathPath).Hash.ToLowerInvariant() -cne $proof.runtime_classpath_sha256){throw 'exact_runtime_classpath'}
$classpath=[IO.File]::ReadAllText([IO.Path]::GetFullPath($ClasspathPath))
$manifestPath=if($CorpusPath){[IO.Path]::GetFullPath($CorpusPath)}else{Join-Path $workspace 'fixtures/oracle-full-service/corpus.json'}
if(!$manifestPath.StartsWith((Join-Path $workspace 'fixtures/oracle-full-service/'),[StringComparison]::OrdinalIgnoreCase)){throw 'trusted_corpus_scope'}
Assert-OwnedNoReparse $manifestPath
Assert-OwnedHash $manifestPath $CorpusSha256
$manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$jdk=Join-Path $workspace '.local/sprint03/oracle/jdk/jdk-11.0.32.1+1'
$java=Join-Path $jdk 'bin/java.exe';$javac=Join-Path $jdk 'bin/javac.exe'
Assert-OwnedHash $java '9FCC7D5D43918E389DF240D44601C98A4D3AA9E7D0CBBD6D208304E0B574C7E2'
Assert-OwnedHash $javac '9A54EFFE7088D627A433A61DA65D71FB420B5A67D163577C6C4F0EC3DFC3DBD6'
$pwsh=(Get-Process -Id $PID).Path
Assert-OwnedHash $pwsh '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$classes=Join-Path $output 'classes';[IO.Directory]::CreateDirectory($classes)|Out-Null
$harness=Join-Path $PSScriptRoot 'full-service-harness.java'
function ArgFile([string]$Path,[string[]]$Arguments){
 $text=(@($Arguments|ForEach-Object {'"'+$_.Replace('\','\\').Replace('"','\"')+'"'}) -join "`n")+"`n"
 $f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$b=[Text.UTF8Encoding]::new($false).GetBytes($text);$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()}
}
function Native([string]$Label,[string]$Program,[string[]]$Arguments,[object[]]$Pins){
 $out=Join-Path $output $Label
 $c=@{program=$Program;program_sha256=Get-OwnedHash $Program;arguments=$Arguments;working_directory=(Join-Path $own 'temp');cwd=(Join-Path $own 'temp');output_directory=$out;timeout_seconds=60;max_output_bytes=4MB;worker_go=$true;worker_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'full-service-worker.ps1');module_sha256='E56CABB8D5006F96A18B9FCFC0FF6E342DFC8085D6402A137B3D54CF177E7425';pwsh_sha256=Get-OwnedHash $pwsh;environment=@{JAVA_HOME=$jdk;TEMP=(Join-Path $own 'temp');TMP=(Join-Path $own 'temp');JAVA_TOOL_OPTIONS='';JDK_JAVA_OPTIONS='';_JAVA_OPTIONS=''};pins=$Pins;inputs=$Pins}
 $config=Join-Path $output ($Label+'.config.json');Write-OwnedJson $config $c
 & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'full-service-run.ps1') -ConfigPath $config -ConfigSha256 (Get-OwnedHash $config) | Out-Null
 if($LASTEXITCODE -ne 0){throw ('observer_native_failed_'+$Label)}
 $actual=Get-Content (Join-Path $out 'child.process.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($actual.native_exit -ne 0 -or !$actual.stdout_complete -or !$actual.stderr_complete -or $actual.output_limit -or $actual.capture_fault -or $actual.drain_timeout){throw ('observer_capture_failed_'+$Label)}
 return @{path=$out;native_exit=$actual.native_exit;process_proof_sha256=Get-OwnedHash (Join-Path $out 'child.process.json');coordinator_result_sha256=Get-OwnedHash (Join-Path $out 'result.json')}
}
$compileArgs=Join-Path $output 'javac.args'
ArgFile $compileArgs @('-proc:none','-encoding','UTF-8','-classpath',$classpath,'-d',$classes,$harness)
$compile=Native 'compile' $javac @('-J-Xmx512m',('-J-Duser.home='+(Join-Path $own 'home')),('-J-Djava.io.tmpdir='+(Join-Path $own 'temp')),('@'+$compileArgs)) @(@{path=$compileArgs;sha256=Get-OwnedHash $compileArgs},@{path=$harness;sha256=Get-OwnedHash $harness})
$harnessClass=Join-Path $classes 'FullServiceHarness.class';$classHash=Get-OwnedHash $harnessClass
$observerClasses=@(Get-ChildItem $classes -Recurse -File -Filter '*.class'|ForEach-Object {@{path=$_.FullName;sha256=Get-OwnedHash $_.FullName}})
$regressionArgs=Join-Path $output 'adapter-regression.args';$regressionJson=Join-Path $output 'adapter-regression.json'
ArgFile $regressionArgs @('-Xmx512m','-da',('-Duser.home='+(Join-Path $own 'home')),('-Djava.io.tmpdir='+(Join-Path $own 'temp')),'-classpath',($classes+[IO.Path]::PathSeparator+$classpath),'FullServiceHarness','--self-test',$regressionJson)
$adapterRegression=Native 'adapter-regression' $java @('@'+$regressionArgs) (@(@{path=$regressionArgs;sha256=Get-OwnedHash $regressionArgs})+$observerClasses)
if((Get-Content $regressionJson -Raw|ConvertFrom-Json).status -cne 'PASS'){throw 'adapter_hierarchy_regression'}
$rows=@()
foreach($case in $manifest.corpus){
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]'2026-10-20T19:46:17Z'){throw 'observer_sprint_freeze'}
 $fixturePath=Join-Path (Split-Path -Parent $manifestPath) $case.file
 Assert-OwnedHash $fixturePath $case.sha256
 $json=Join-Path $output ($case.id+'.json');$argsFile=Join-Path $output ($case.id+'.args')
 ArgFile $argsFile @('-Xmx512m','-da',('-Duser.home='+(Join-Path $own 'home')),('-Djava.io.tmpdir='+(Join-Path $own 'temp')),'-Dfile.encoding=UTF-8','-Duser.timezone=UTC','-classpath',($classes+[IO.Path]::PathSeparator+$classpath),'FullServiceHarness',$fixturePath,$case.extension,$json)
 $native=Native $case.id $java @('@'+$argsFile) (@(@{path=$argsFile;sha256=Get-OwnedHash $argsFile},@{path=$fixturePath;sha256=$case.sha256})+$observerClasses)
 $observed=Get-Content $json -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($observed.input_sha256 -cne $case.sha256 -or $observed.service_class_sha256 -cne $proof.service_class_sha256 -or $observed.assertions_enabled -or $observed.public_importLog_executed){throw 'actual_observer_binding'}
 $checks=@{outcome=($observed.status -ceq $(if($case.expected_service.outcome -ceq 'success'){'success'}else{'refused'}))}
 if($case.expected_service.ContainsKey('traces')){$checks.traces=($observed.ContainsKey('log') -and $observed.log.trace_count -eq $case.expected_service.traces)}
 if($case.expected_service.ContainsKey('events')){$checks.events=($observed.ContainsKey('log') -and $observed.log.event_count -eq $case.expected_service.events)}
 if($case.expected_service.ContainsKey('log_name')){
  $actualName=$null
  if($observed.ContainsKey('log')){$names=@($observed.log.attributes|Where-Object {$_.key -ceq 'concept:name'});if($names.Count -eq 1){$actualName=$names[0].value}}
  $checks.log_name=($actualName -ceq $case.expected_service.log_name)
 }
 if($case.expected_service.ContainsKey('activities')){
  $names=@()
  if($observed.ContainsKey('log')){foreach($trace in $observed.log.traces){foreach($event in $trace.events){$a=@($event.attributes|Where-Object {$_.key -ceq 'concept:name'});if($a.Count -eq 1){$names+=,$a[0].value}}}}
  $checks.activities=((ConvertTo-Json -InputObject $names -Compress) -ceq (ConvertTo-Json -InputObject @($case.expected_service.activities) -Compress))
 }
 if($case.expected_service.ContainsKey('timestamp_millis')){
  $times=@()
  if($observed.ContainsKey('log')){foreach($trace in $observed.log.traces){foreach($event in $trace.events){$a=@($event.attributes|Where-Object {$_.key -ceq 'time:timestamp' -and $_.type -ceq 'date'});if($a.Count -eq 1){$times+=,[long]$a[0].value}}}}
  $checks.timestamp_millis=((ConvertTo-Json -InputObject $times -Compress) -ceq (ConvertTo-Json -InputObject @($case.expected_service.timestamp_millis) -Compress))
 }
 if($case.expected_service.ContainsKey('classifiers')){$checks.classifiers=($observed.ContainsKey('log') -and $observed.log.classifiers.Count -eq $case.expected_service.classifiers)}
 if($case.expected_service.ContainsKey('message')){$checks.message=($observed.ContainsKey('exception') -and $observed.exception.message -ceq $case.expected_service.message)}
 foreach($expectedKey in $case.expected_service.Keys){if(!$checks.ContainsKey($expectedKey)){throw ('unhandled_manual_expectation_'+$expectedKey)}}
 if($case.ContainsKey('typed_manual_expectation')){
  $typed=$case.typed_manual_expectation;$targets=@()
  if($observed.ContainsKey('log') -and $observed.log.traces.Count -eq 1 -and $observed.log.traces[0].events.Count -eq 1){$targets=@($observed.log.traces[0].events[0].attributes|Where-Object {$_.key -ceq $typed.target_key})}
  $checks.typed_manual_target=($targets.Count -eq 1 -and $targets[0].type -ceq $typed.type)
  if($checks.typed_manual_target){
   if($typed.ContainsKey('ordered_values')){$checks.typed_manual_target=((ConvertTo-Json -InputObject @($targets[0].value|ForEach-Object {$_.value}) -Compress) -ceq (ConvertTo-Json -InputObject @($typed.ordered_values) -Compress))}
   if($typed.ContainsKey('value')){$checks.typed_manual_target=($checks.typed_manual_target -and $targets[0].value -ceq $typed.value)}
   if($typed.ContainsKey('children')){$checks.typed_manual_target=($checks.typed_manual_target -and (ConvertTo-Json -InputObject @($targets[0].children) -Compress) -ceq (ConvertTo-Json -InputObject @($typed.children) -Compress))}
  }
 }
 $rows+=@{id=$case.id;input_sha256=$case.sha256;observation=$observed;observation_sha256=Get-OwnedHash $json;native=$native;manual_expected_checks=$checks}
 Write-Output ('ACTUAL_FULL_SERVICE_CASE '+$case.id+' '+$observed.status)
}
foreach($f in (@($proof.runtime_files)+$observerClasses)){Assert-OwnedHash $f.path $f.sha256}
$result=@{schema_version=1;utc=[DateTime]::UtcNow.ToString('o');status='ACTUAL_UNCHANGED_FULL_CLASS_PRIVATE_IMPORTER_CORPUS_OBSERVED';selected_path='unchanged_full_class.private.importFromStream';public_importLog_executed=$false;core_commit='bbf24dfd43e72d6992392465f875a4367cbe792b';corpus_sha256=Get-OwnedHash $manifestPath;case_count=$rows.Count;batch_source_sha256=Get-OwnedHash $PSCommandPath;canonical_build_proof_sha256=Get-OwnedHash $BuildProofPath;observer_source_sha256=Get-OwnedHash $harness;observer_class_sha256=$classHash;observer_classes=$observerClasses;compile=$compile;adapter_regression=$adapterRegression;adapter_regression_sha256=Get-OwnedHash $regressionJson;cases=$rows;limits=@('No authenticated/persistent public importLog, Portal or enterprise parity claim','Default actual factory/registry observed, assertions explicitly disabled','ByteArrayInputStream observation delegates read/mark/reset; adapter never rewinds','Only the named trusted frozen finite corpus; no arbitrary XML/XXE security claim')}
Write-OwnedJson (Join-Path $output 'reference-results.json') $result
Write-Output ('FULL_SERVICE_REFERENCE_REPORT '+(Join-Path $output 'reference-results.json'))
