param([Parameter(Mandatory)][string]$AttemptPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$owned=Join-Path $workspace '.local/sprint18/service'
$attempt=[IO.Path]::GetFullPath($AttemptPath)
if(!$attempt.StartsWith($owned+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'private_attempt'}
Import-Module (Join-Path $PSScriptRoot 'public-service-runtime.psm1') -Force -DisableNameChecking
[void](New-OwnedPrivateDirectory $attempt)
foreach($part in @('home','temp','classes')){[void](New-OwnedPrivateDirectory (Join-Path $attempt $part))}
$oldClasspath=Join-Path $workspace '.local/sprint16/service/runtime-classpath02.txt'
Assert-OwnedHash $oldClasspath 'FAD4762128F2E3120A7A7635B2E2078EE3A24C8D2CCF63C72EB4F628F8753DA3'
$classpath=[IO.File]::ReadAllText($oldClasspath)
$classpathPath=Join-Path $attempt 'runtime-classpath.txt'
[IO.File]::WriteAllText($classpathPath,$classpath,[Text.UTF8Encoding]::new($false))
$proof=Join-Path $workspace '.local/sprint16/service/canonical-build-proof02.json'
Assert-OwnedHash $proof '976DB2B8712233ABD6323286E0AD0AD0B0198D74147FC35596A18F13A8BEDD83'
$manifest=Join-Path $workspace 'fixtures/oracle-core-filter/corpus.json'
Assert-OwnedHash $manifest '0997ACC2AF6514C0D799181F78CFEF217BDDB375DEF14646F6864F8257CFCE6C'
$jdk=Join-Path $workspace '.local/sprint03/oracle/jdk/jdk-11.0.32.1+1'
$compiler=Join-Path $jdk 'bin/javac.exe'
Assert-OwnedHash $compiler '9A54EFFE7088D627A433A61DA65D71FB420B5A67D163577C6C4F0EC3DFC3DBD6'
$pwsh=(Get-Process -Id $PID).Path
Assert-OwnedHash $pwsh '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$harness=Join-Path $PSScriptRoot 'core-filter-harness.java'
$observer=Join-Path $PSScriptRoot 'core-filter-xes-observer.java'
$argPath=Join-Path $attempt 'javac.args'
$compileArguments=@('-proc:none','-encoding','UTF-8','-classpath',$classpath,'-d',(Join-Path $attempt 'classes'),$harness,$observer)
$argText=(@($compileArguments|ForEach-Object {'"'+$_.Replace('\','\\').Replace('"','\"')+'"'}) -join "`n")+"`n"
[IO.File]::WriteAllText($argPath,$argText,[Text.UTF8Encoding]::new($false))
$logging=Join-Path $attempt 'logback-console.xml'
[IO.File]::WriteAllText($logging,'<configuration><appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender"><encoder><pattern>%level %logger{36} - %msg%n</pattern></encoder></appender><root level="INFO"><appender-ref ref="STDOUT"/></root></configuration>',[Text.UTF8Encoding]::new($false))
$pins=@($harness,$observer,$argPath,$classpathPath,$manifest,$logging,$proof)|ForEach-Object {@{path=$_;sha256=Get-OwnedHash $_}}
$config=@{program=$compiler;program_sha256=Get-OwnedHash $compiler;arguments=@('-J-Xmx512m',('-J-Duser.home='+(Join-Path $attempt 'home')),('-J-Djava.io.tmpdir='+(Join-Path $attempt 'temp')),('@'+$argPath));working_directory=(Join-Path $attempt 'temp');cwd=(Join-Path $attempt 'temp');output_directory=(Join-Path $attempt 'compile');timeout_seconds=180;max_output_bytes=8MB;worker_go=$true;worker_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-worker.ps1');module_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-runtime.psm1');pwsh_sha256=Get-OwnedHash $pwsh;environment=@{JAVA_HOME=$jdk;TEMP=(Join-Path $attempt 'temp');TMP=(Join-Path $attempt 'temp');JAVA_TOOL_OPTIONS='';JDK_JAVA_OPTIONS='';_JAVA_OPTIONS=''};pins=@($pins);inputs=@($pins);runtime_manifest=@{path=$proof;sha256=Get-OwnedHash $proof}}
$configPath=Join-Path $attempt 'compile.config.json';Write-OwnedJson $configPath $config
Write-Output (@{status='PREPARED_ONLY_NO_NATIVE_COMMAND';attempt=$attempt;compile_config=$configPath;compile_config_sha256=Get-OwnedHash $configPath;harness_sha256=Get-OwnedHash $harness;observer_sha256=Get-OwnedHash $observer;runner_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'public-service-run.ps1')}|ConvertTo-Json)
