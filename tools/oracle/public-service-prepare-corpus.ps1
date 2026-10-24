param([Parameter(Mandatory)][string]$AttemptPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$owned=Join-Path $workspace '.local/sprint18/service'
$attempt=[IO.Path]::GetFullPath($AttemptPath)
if(!$attempt.StartsWith($owned+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'private_attempt'}
Import-Module (Join-Path $PSScriptRoot 'public-service-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $attempt
$compileResult=Join-Path $attempt 'compile/child.process.json'
$compile=Get-Content $compileResult -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($compile.native_exit -ne 0 -or !$compile.stdout_complete -or !$compile.stderr_complete -or $compile.output_limit -or $compile.capture_fault -or $compile.drain_timeout){throw 'completed_real_compile_required'}
$classes=Join-Path $attempt 'classes'
$classPins=@(Get-ChildItem $classes -File -Recurse -Filter '*.class'|ForEach-Object {@{path=$_.FullName;sha256=Get-OwnedHash $_.FullName}})
if(@($classPins|Where-Object {[IO.Path]::GetFileName($_.path) -ceq 'PublicServiceCorpusHarness.class'}).Count -ne 1){throw 'actual_corpus_harness_class'}
$classpathPath=Join-Path $attempt 'runtime-classpath.txt';$classpath=[IO.File]::ReadAllText($classpathPath)
Assert-OwnedHash $classpathPath 'FAD4762128F2E3120A7A7635B2E2078EE3A24C8D2CCF63C72EB4F628F8753DA3'
$logging=Join-Path $attempt 'logback-console.xml'
$jdk=Join-Path $workspace '.local/sprint03/oracle/jdk/jdk-11.0.32.1+1'
$java=Join-Path $jdk 'bin/java.exe'
Assert-OwnedHash $java '9FCC7D5D43918E389DF240D44601C98A4D3AA9E7D0CBBD6D208304E0B574C7E2'
$pwsh=(Get-Process -Id $PID).Path
Assert-OwnedHash $pwsh '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$proof=Join-Path $workspace '.local/sprint16/service/canonical-build-proof02.json'
Assert-OwnedHash $proof '976DB2B8712233ABD6323286E0AD0AD0B0198D74147FC35596A18F13A8BEDD83'
$sourceFiles=@('public-service-harness.java','public-service-xes-observer.java','public-service-corpus-harness.java')|ForEach-Object {Join-Path $PSScriptRoot $_}
$manifests=@(@{path=(Join-Path $workspace 'fixtures/oracle-public-service/corpus.json');sha256='60878D96CDB6D3882FF1BC11CFA32E8207F2457B6C76C47C9FC73713AD08A648'},@{path=(Join-Path $workspace 'fixtures/oracle-public-service/supplement-flat/corpus.json');sha256='05AB614AAA1A047251D009C096801152B0258B072D8E65A156100A2761BE4202'})
$plan=@()
foreach($manifest in $manifests){
 Assert-OwnedHash $manifest.path $manifest.sha256
 $corpus=(Get-Content $manifest.path -Raw|ConvertFrom-Json -AsHashtable).corpus
 foreach($case in $corpus){
  if($case.id -cnotmatch '^[a-z][a-z0-9-]{0,39}$' -or $case.perspective){throw 'finite_false_path_cases_only'}
  $fixture=Join-Path (Split-Path $manifest.path) $case.file;Assert-OwnedHash $fixture $case.sha256
  $runName=$case.id;$argPath=Join-Path $attempt ($runName+'.args');$state=Join-Path $attempt ($runName+'-state');$observation=Join-Path $attempt ($runName+'.json')
  foreach($fresh in @($argPath,$state,$observation,(Join-Path $attempt $runName))){if(Test-Path $fresh){throw 'fresh_native_attempt_required'}}
  $arguments=@('-Xmx768m','-da',('-Duser.home='+(Join-Path $attempt 'home')),('-Djava.io.tmpdir='+(Join-Path $attempt 'temp')),('-Dlogback.configurationFile='+$logging),'-Dfile.encoding=UTF-8','-Duser.timezone=UTC','-Djava.awt.headless=true','-classpath',($classes+[IO.Path]::PathSeparator+$classpath),'PublicServiceCorpusHarness',$state,$manifest.path,$case.id,$observation)
  $argText=(@($arguments|ForEach-Object {'"'+$_.Replace('\','\\').Replace('"','\"')+'"'}) -join "`n")+"`n"
  [IO.File]::WriteAllText($argPath,$argText,[Text.UTF8Encoding]::new($false))
  $pins=@(@($sourceFiles+$argPath+$classpathPath+$manifest.path+$fixture+$logging+$proof+$compileResult)|ForEach-Object {@{path=$_;sha256=Get-OwnedHash $_}})+$classPins
  $config=@{program=$java;program_sha256=Get-OwnedHash $java;arguments=@('@'+$argPath);working_directory=(Join-Path $attempt 'temp');cwd=(Join-Path $attempt 'temp');output_directory=(Join-Path $attempt $runName);timeout_seconds=180;max_output_bytes=8MB;worker_go=$true;worker_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-worker.ps1');module_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-runtime.psm1');pwsh_sha256=Get-OwnedHash $pwsh;environment=@{JAVA_HOME=$jdk;TEMP=(Join-Path $attempt 'temp');TMP=(Join-Path $attempt 'temp');JAVA_TOOL_OPTIONS='';JDK_JAVA_OPTIONS='';_JAVA_OPTIONS=''};pins=$pins;inputs=$pins;runtime_manifest=@{path=$proof;sha256=Get-OwnedHash $proof}}
  $configPath=Join-Path $attempt ($runName+'.config.json');Write-OwnedJson $configPath $config
  $plan+=,@{id=$case.id;config=$configPath;config_sha256=Get-OwnedHash $configPath;observation=$observation;state=$state;fixture_sha256=$case.sha256;corpus_sha256=$manifest.sha256}
 }
}
Write-OwnedJson (Join-Path $attempt 'observer-classes.json') $classPins
$planPath=Join-Path $attempt 'execution-plan.json';Write-OwnedJson $planPath @{status='PREPARED_ONLY_NO_JAVA_EXECUTION';case_count=$plan.Count;cases=$plan;observer_classes=$classPins;runner_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-run.ps1')}
Write-Output (@{plan=$planPath;sha256=Get-OwnedHash $planPath;cases=$plan.Count;compiled_classes=$classPins.Count}|ConvertTo-Json)
