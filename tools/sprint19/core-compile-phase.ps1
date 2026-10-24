param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha,[switch]$FunctionsOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha){throw 'config_pin'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
function Assert-CorePins {
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 Assert-OwnedHash $c.canonical_proof $c.canonical_proof_sha
 Assert-OwnedHash $c.classpath_file $c.classpath_sha
 Assert-OwnedHash $c.javac $c.javac_sha
 Assert-OwnedHash $c.java $c.java_sha
 foreach($source in $c.java_sources){Assert-OwnedHash $source.path $source.sha256}
}
function Get-CoreBlob([string]$Path,[long]$Length) {
 Assert-OwnedNoReparse $Path
 $item=Get-Item -LiteralPath $Path -Force
 if(!$item.PSIsContainer -and $item.Length -eq $Length){
  $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
  $stream=[IO.File]::OpenRead($Path)
  try{
   $hash.AppendData([Text.Encoding]::ASCII.GetBytes(('blob '+$Length+[char]0)))
   $buffer=[byte[]]::new(65536)
   while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0){$hash.AppendData($buffer,0,$count)}
   return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
  }finally{$stream.Dispose();$hash.Dispose()}
 }
 throw 'canonical_source_type_or_length'
}
function Assert-CoreCanonical {
 Assert-CorePins
 $proof=Get-Content -LiteralPath $c.canonical_proof -Raw|ConvertFrom-Json -AsHashtable
 if($proof.unchanged_source.Count -ne 5763 -or $proof.runtime_files.Count -ne 285 -or $proof.classpath_entries.Count -ne 189){throw 'canonical_inventory_counts'}
 foreach($row in $proof.unchanged_source){
  $root=[IO.Path]::GetFullPath($c.canonical_source_root)+[IO.Path]::DirectorySeparatorChar
  $path=[IO.Path]::GetFullPath((Join-Path $c.canonical_source_root $row.path))
  if(!$path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'source_path_escape'}
  if((Get-CoreBlob $path $row.bytes) -cne $row.git_blob){throw 'canonical_source_git_blob'}
 }
 foreach($row in $proof.runtime_files){
  Assert-OwnedNoReparse $row.path
  if((Get-Item -LiteralPath $row.path).Length -ne $row.bytes){throw 'canonical_runtime_length'}
  Assert-OwnedHash $row.path $row.sha256.ToUpperInvariant()
 }
}
function Write-CoreArgs([string]$Path,[string[]]$Arguments){
 $lines=foreach($argument in $Arguments){
  if($argument.Contains([char]0) -or $argument.Contains([char]10) -or $argument.Contains([char]13)){throw 'argfile_control_character'}
  '"'+$argument.Replace('\','\\').Replace('"','\"')+'"'
 }
 $content=[Text.Encoding]::UTF8.GetBytes(($lines -join [char]10)+[char]10)
 $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
 try{$stream.Write($content);$stream.Flush($true)}finally{$stream.Dispose()}
}
function New-CoreEnvironment {
 Assert-OwnedPrivateDirectory $c.output
 foreach($folder in @('home','temp','prefs-user','prefs-system','cwd')){New-OwnedPrivateDirectory (Join-Path $c.output $folder)|Out-Null}
 $logback=Join-Path $c.output 'logback.xml'
 if(Test-Path -LiteralPath $logback){throw 'fresh_logback_required'}
 [IO.File]::WriteAllText($logback,'<configuration><appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender"><encoder><pattern>%level %logger - %msg%n</pattern></encoder></appender><root level="WARN"><appender-ref ref="CONSOLE"/></root></configuration>',[Text.UTF8Encoding]::new($false))
 # Empty inherited JVM option variables. Never emit their original values.
 foreach($variable in @('JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS')){[Environment]::SetEnvironmentVariable($variable,$null,'Process')}
 return @{JAVA_TOOL_OPTIONS='';JDK_JAVA_OPTIONS='';_JAVA_OPTIONS='';TEMP=(Join-Path $c.output 'temp');TMP=(Join-Path $c.output 'temp')}
}
function Get-CoreJvmArgs {
 return @('-Xmx512m','-XX:-UsePerfData','-da',('-Duser.home='+ (Join-Path $c.output 'home')),('-Djava.io.tmpdir='+ (Join-Path $c.output 'temp')),('-Djava.util.prefs.userRoot='+ (Join-Path $c.output 'prefs-user')),('-Djava.util.prefs.systemRoot='+ (Join-Path $c.output 'prefs-system')),('-Dlogback.configurationFile='+ (Join-Path $c.output 'logback.xml')),'-Dfile.encoding=UTF-8','-Duser.timezone=UTC','-Djava.awt.headless=true')
}
function Get-CoreClasses([string]$Directory){
 Assert-OwnedPrivateDirectory $Directory
 return @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force|Sort-Object FullName|ForEach-Object{Assert-OwnedNoReparse $_.FullName;@{path=[IO.Path]::GetRelativePath($Directory,$_.FullName);bytes=$_.Length;sha256=Get-OwnedHash $_.FullName}})
}
function Assert-CoreClassSet([object[]]$Actual,[object[]]$Expected){
 if($Actual.Count -ne $Expected.Count){throw 'full_class_set_count'}
 $seen=@{}
 foreach($row in $Expected){
  if($seen.ContainsKey($row.path)){throw 'duplicate_class_path'}
  $seen[$row.path]=$true
  $matches=@($Actual|Where-Object{$_.path -ceq $row.path})
  if($matches.Count -ne 1 -or $matches[0].bytes -ne $row.bytes -or $matches[0].sha256 -cne $row.sha256){throw 'full_class_set_pin'}
 }
}
if($FunctionsOnly){return}
Assert-CoreCanonical
if($c.java_sources.Count -ne 3){throw 'three_own_java_sources_required'}
$environment=New-CoreEnvironment
$classes=New-OwnedPrivateDirectory (Join-Path $c.output 'classes')
$classpath=[IO.File]::ReadAllText($c.classpath_file).TrimEnd([char]13,[char]10)
if($classpath.Contains([char]10) -or $classpath.Contains([char]13)){throw 'single_classpath_required'}
$argfile=Join-Path $c.output 'javac.args'
Write-CoreArgs $argfile (@('-proc:none','-encoding','UTF-8','-classpath',$classpath,'-d',$classes)+@($c.java_sources|ForEach-Object{$_.path}))
$compilerJvm=@(Get-CoreJvmArgs|ForEach-Object{'-J'+$_})
$result=Invoke-OwnedPhaseCommand $c.javac $c.javac_sha ($compilerJvm+@('@'+$argfile)) (Join-Path $c.output 'cwd') $c.output 'javac' $environment 180 8MB
$files=Get-CoreClasses $classes
if($files.Count -eq 0 -or @($files|Where-Object{$_.path -notlike '*.class'}).Count -ne 0){throw 'only_actual_class_outputs_required'}
Assert-CoreCanonical
Write-OwnedJson (Join-Path $c.output 'core-build-proof.json') @{status='ACTUAL_OWN_JAVA_CLASSES_COMPILED_NO_R5_ENGINE_EXECUTION';classes=$classes;class_files=$files;classpath_sha256=$c.classpath_sha;canonical_proof_sha256=$c.canonical_proof_sha;javac_sha256=$c.javac_sha;java_sha256=$c.java_sha;java_sources=$c.java_sources;native_exit=$result.native_exit;canonical_5763_and_285_readback_before_after=$true;argfile_sha256=Get-OwnedHash $argfile;no_engine_execution=$true}
