param(
 [Parameter(Mandatory)][string]$ClasspathPath,
 [Parameter(Mandatory)][string]$BuildProofPath,
 [Parameter(Mandatory)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$own=Join-Path $workspace '.local/sprint16/service'
$output=[IO.Path]::GetFullPath($OutputPath)
if(!$output.StartsWith($own+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'new_private_miner_scope'}
Import-Module (Join-Path $PSScriptRoot 'full-service-runtime.psm1') -Force -DisableNameChecking
[void](New-OwnedPrivateDirectory $output)
$proof=Get-Content $BuildProofPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($proof.original_source_files -ne 5763){throw 'complete_original_source_proof'}
$oldProof=Get-Content (Join-Path $own 'canonical-build-proof02.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Assert-OwnedHash (Join-Path $own 'canonical-build-proof02.json') '976DB2B8712233ABD6323286E0AD0AD0B0198D74147FC35596A18F13A8BEDD83'
foreach($f in (@($proof.runtime_files)+@($oldProof.runtime_files))){Assert-OwnedHash $f.path $f.sha256}
if((Get-FileHash $ClasspathPath).Hash.ToLowerInvariant() -cne $proof.runtime_classpath_sha256){throw 'exact_runtime_classpath'}
$classpath=[IO.File]::ReadAllText([IO.Path]::GetFullPath($ClasspathPath))
$manifestPath=Join-Path $workspace 'fixtures/oracle-splitminer/corpus.json'
Assert-OwnedHash $manifestPath '642254ED2EE675FD4EE2167CE353C75913F0E049AAB681F668DE6184431DAAD0'
$manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
$jdk=Join-Path $workspace '.local/sprint03/oracle/jdk/jdk-11.0.32.1+1'
$java=Join-Path $jdk 'bin/java.exe';$javac=Join-Path $jdk 'bin/javac.exe'
Assert-OwnedHash $java '9FCC7D5D43918E389DF240D44601C98A4D3AA9E7D0CBBD6D208304E0B574C7E2'
Assert-OwnedHash $javac '9A54EFFE7088D627A433A61DA65D71FB420B5A67D163577C6C4F0EC3DFC3DBD6'
$pwsh=(Get-Process -Id $PID).Path
Assert-OwnedHash $pwsh '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$classes=Join-Path $output 'classes';[IO.Directory]::CreateDirectory($classes)|Out-Null
$harness=Join-Path $PSScriptRoot 'full-miner-harness.java'
function ArgFile([string]$Path,[string[]]$Arguments){
 $text=(@($Arguments|ForEach-Object {'"'+$_.Replace('\','\\').Replace('"','\"')+'"'}) -join "`n")+"`n"
 $f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$b=[Text.UTF8Encoding]::new($false).GetBytes($text);$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()}
}
function Native([string]$Label,[string]$Program,[string[]]$Arguments,[object[]]$Pins){
 $out=Join-Path $output $Label
 $c=@{program=$Program;program_sha256=Get-OwnedHash $Program;arguments=$Arguments;working_directory=(Join-Path $own 'miner-temp01');cwd=(Join-Path $own 'miner-temp01');output_directory=$out;timeout_seconds=120;max_output_bytes=4MB;worker_go=$true;worker_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'full-service-worker.ps1');module_sha256='E56CABB8D5006F96A18B9FCFC0FF6E342DFC8085D6402A137B3D54CF177E7425';pwsh_sha256=Get-OwnedHash $pwsh;environment=@{JAVA_HOME=$jdk;TEMP=(Join-Path $own 'miner-temp01');TMP=(Join-Path $own 'miner-temp01');JAVA_TOOL_OPTIONS='';JDK_JAVA_OPTIONS='';_JAVA_OPTIONS=''};pins=$Pins;inputs=$Pins}
 $config=Join-Path $output ($Label+'.config.json');Write-OwnedJson $config $c
 & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'full-service-run.ps1') -ConfigPath $config -ConfigSha256 (Get-OwnedHash $config)|Out-Null
 if($LASTEXITCODE -ne 0){throw ('miner_native_failed_'+$Label)}
 $actual=Get-Content (Join-Path $out 'child.process.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($actual.native_exit -ne 0 -or !$actual.stdout_complete -or !$actual.stderr_complete -or $actual.output_limit -or $actual.capture_fault -or $actual.drain_timeout){throw ('miner_capture_failed_'+$Label)}
 return @{path=$out;native_exit=$actual.native_exit;process_proof_sha256=Get-OwnedHash (Join-Path $out 'child.process.json');coordinator_result_sha256=Get-OwnedHash (Join-Path $out 'result.json')}
}
$compileArgs=Join-Path $output 'javac.args'
ArgFile $compileArgs @('-proc:none','-encoding','UTF-8','-classpath',$classpath,'-d',$classes,$harness)
$compile=Native 'compile' $javac @('-J-Xmx512m',('-J-Duser.home='+(Join-Path $own 'miner-home01')),('-J-Djava.io.tmpdir='+(Join-Path $own 'miner-temp01')),('@'+$compileArgs)) @(@{path=$compileArgs;sha256=Get-OwnedHash $compileArgs},@{path=$harness;sha256=Get-OwnedHash $harness})
$observerClasses=@(Get-ChildItem $classes -Recurse -File -Filter '*.class'|ForEach-Object {@{path=$_.FullName;sha256=Get-OwnedHash $_.FullName}})
$rows=@()
foreach($case in $manifest.corpus){
 $fixturePath=Join-Path (Split-Path -Parent $manifestPath) $case.file
 Assert-OwnedHash $fixturePath $case.sha256
 $json=Join-Path $output ($case.id+'.json');$bpmn=Join-Path $output ($case.id+'.bpmn');$argsFile=Join-Path $output ($case.id+'.args')
 ArgFile $argsFile @('-Xmx768m','-da',('-Duser.home='+(Join-Path $own 'miner-home01')),('-Djava.io.tmpdir='+(Join-Path $own 'miner-temp01')),'-Dfile.encoding=UTF-8','-Duser.timezone=UTC','-Djava.awt.headless=true','-classpath',($classes+[IO.Path]::PathSeparator+$classpath),'FullMinerHarness',$fixturePath,$json,$bpmn)
 $native=Native $case.id $java @('@'+$argsFile) (@(@{path=$argsFile;sha256=Get-OwnedHash $argsFile},@{path=$fixturePath;sha256=$case.sha256})+$observerClasses)
 $observed=Get-Content $json -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($observed.input_sha256 -cne $case.sha256 -or $observed.algorithm_class_sha256 -cne $proof.miner_class_sha256 -or $observed.assertions_enabled){throw 'actual_miner_binding'}
 $checks=@{input_traces=($observed.input_traces -eq $case.trace_count);input_events=($observed.input_events -eq $case.event_count);parameters=((ConvertTo-Json $observed.parameters -Depth 10 -Compress) -ceq (ConvertTo-Json $manifest.parameters -Depth 10 -Compress))}
 # Hashtable enumeration order is not a semantic parameter difference.
 foreach($key in $manifest.parameters.Keys){if($observed.parameters[$key] -cne $manifest.parameters[$key]){throw ('frozen_parameter_'+$key)}}
 $checks.parameters=$true
 if(Test-Path -LiteralPath $bpmn){Assert-OwnedHash $bpmn $observed.bpmn_sha256}
 $rows+=@{id=$case.id;input_sha256=$case.sha256;observation=$observed;observation_sha256=Get-OwnedHash $json;native=$native;input_manual_checks=$checks}
 Write-Output ('ACTUAL_SPLITMINER_CASE '+$case.id+' '+$observed.status)
}
foreach($f in (@($proof.runtime_files)+@($oldProof.runtime_files)+$observerClasses)){Assert-OwnedHash $f.path $f.sha256}
$result=@{schema_version=1;utc=[DateTime]::UtcNow.ToString('o');status='ACTUAL_CANONICAL_SPLITMINER_FINITE_CORPUS_OBSERVED';case_count=$rows.Count;corpus_sha256=Get-OwnedHash $manifestPath;batch_source_sha256=Get-OwnedHash $PSCommandPath;observer_source_sha256=Get-OwnedHash $harness;observer_classes=$observerClasses;canonical_build_proof_sha256=Get-OwnedHash $BuildProofPath;old_r2_runtime_285_unchanged=$true;compile=$compile;cases=$rows;limits=@('Finite trusted corpus and explicit parameter tuple only','No Rust algorithm implementation or general mining quality claim','Upstream internal safe fallback recorded by native logs; bare DFG fallback labeled separately','Raw random graph identifiers retained, no byte-stable graph/export claim')}
Write-OwnedJson (Join-Path $output 'reference-results.json') $result
Write-Output ('FULL_MINER_REFERENCE_REPORT '+(Join-Path $output 'reference-results.json'))
