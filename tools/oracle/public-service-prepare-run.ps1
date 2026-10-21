param([Parameter(Mandatory)][string]$AttemptPath,[Parameter(Mandatory)][string]$RunName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($RunName -cnotmatch '^[a-z][a-z0-9-]{0,39}$'){throw 'finite_run_name'}
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
if(@($classPins|Where-Object {[IO.Path]::GetFileName($_.path) -ceq 'PublicServiceHarness.class'}).Count -ne 1){throw 'actual_harness_class'}
$classpathPath=Join-Path $attempt 'runtime-classpath.txt';$classpath=[IO.File]::ReadAllText($classpathPath)
Assert-OwnedHash $classpathPath 'FAD4762128F2E3120A7A7635B2E2078EE3A24C8D2CCF63C72EB4F628F8753DA3'
$manifest=Join-Path $workspace 'fixtures/oracle-public-service/corpus.json'
Assert-OwnedHash $manifest '60878D96CDB6D3882FF1BC11CFA32E8207F2457B6C76C47C9FC73713AD08A648'
$fixture=Join-Path $workspace 'fixtures/oracle-public-service/typed-defaults.xes'
$fixtureCase=(Get-Content $manifest -Raw|ConvertFrom-Json -AsHashtable).corpus|Where-Object id -CEQ 'minimal-home-private'
Assert-OwnedHash $fixture $fixtureCase.sha256
$logging=Join-Path $attempt 'logback-console.xml'
$jdk=Join-Path $workspace '.local/sprint03/oracle/jdk/jdk-11.0.32.1+1'
$java=Join-Path $jdk 'bin/java.exe'
Assert-OwnedHash $java '9FCC7D5D43918E389DF240D44601C98A4D3AA9E7D0CBBD6D208304E0B574C7E2'
$pwsh=(Get-Process -Id $PID).Path
Assert-OwnedHash $pwsh '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$argPath=Join-Path $attempt ($RunName+'.args');$state=Join-Path $attempt ($RunName+'-state');$observation=Join-Path $attempt ($RunName+'.json')
foreach($fresh in @($argPath,$state,$observation,(Join-Path $attempt $RunName))){if(Test-Path $fresh){throw 'fresh_native_attempt_required'}}
$arguments=@('-Xmx768m','-da',('-Duser.home='+(Join-Path $attempt 'home')),('-Djava.io.tmpdir='+(Join-Path $attempt 'temp')),('-Dlogback.configurationFile='+$logging),'-Dfile.encoding=UTF-8','-Duser.timezone=UTC','-Djava.awt.headless=true','-classpath',($classes+[IO.Path]::PathSeparator+$classpath),'PublicServiceHarness',$state,$fixture,$observation)
$argText=(@($arguments|ForEach-Object {'"'+$_.Replace('\','\\').Replace('"','\"')+'"'}) -join "`n")+"`n"
[IO.File]::WriteAllText($argPath,$argText,[Text.UTF8Encoding]::new($false))
$proof=Join-Path $workspace '.local/sprint16/service/canonical-build-proof02.json'
$sourceFiles=@((Join-Path $PSScriptRoot 'public-service-harness.java'),(Join-Path $PSScriptRoot 'public-service-xes-observer.java'))
$pins=@(@($sourceFiles+$argPath+$classpathPath+$manifest+$fixture+$logging+$proof+$compileResult)|ForEach-Object {@{path=$_;sha256=Get-OwnedHash $_}})+$classPins
$config=@{program=$java;program_sha256=Get-OwnedHash $java;arguments=@('@'+$argPath);working_directory=(Join-Path $attempt 'temp');cwd=(Join-Path $attempt 'temp');output_directory=(Join-Path $attempt $RunName);timeout_seconds=180;max_output_bytes=8MB;worker_go=$true;worker_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-worker.ps1');module_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-runtime.psm1');pwsh_sha256=Get-OwnedHash $pwsh;environment=@{JAVA_HOME=$jdk;TEMP=(Join-Path $attempt 'temp');TMP=(Join-Path $attempt 'temp');JAVA_TOOL_OPTIONS='';JDK_JAVA_OPTIONS='';_JAVA_OPTIONS=''};pins=$pins;inputs=$pins;runtime_manifest=@{path=$proof;sha256=Get-OwnedHash $proof}}
$configPath=Join-Path $attempt ($RunName+'.config.json');Write-OwnedJson $configPath $config
Write-OwnedJson (Join-Path $attempt ($RunName+'-observer-classes.json')) $classPins
Write-Output (@{status='PREPARED_ONLY_NO_JAVA_EXECUTION';config=$configPath;config_sha256=Get-OwnedHash $configPath;state=$state;observation=$observation;class_count=$classPins.Count;source_harness_sha256=Get-OwnedHash $sourceFiles[0]}|ConvertTo-Json)
