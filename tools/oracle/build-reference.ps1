param([Parameter(Mandatory=$true)][string]$JdkHome,[string]$PrivateDir='.local/sprint03/oracle',[string]$Attempt='build-01')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $root
$private=(Resolve-Path $PrivateDir).Path
& (Join-Path $PSScriptRoot 'fetch-reference.ps1') -PrivateDir $private
if($Attempt -notmatch '^build-[a-z0-9-]+$'){throw 'Invalid attempt name'}
$build=Join-Path $private $Attempt
if(Test-Path $build){throw 'Build attempt exists; never overwrite evidence'}
$stub=Join-Path $build 'compile-only'
$classes=Join-Path $build 'classes'
New-Item -ItemType Directory -Force $stub,$classes | Out-Null
# These types only satisfy signatures of the UNUSED XLog overload. No OpenXES implementation.
$types=@{
'XEvent.java'='package org.deckfour.xes.model; public class XEvent { public XEvent(){throw new UnsupportedOperationException("Compile-only OpenXES type");} }';
'XTrace.java'='package org.deckfour.xes.model; public class XTrace { public XTrace(){throw new UnsupportedOperationException("Compile-only OpenXES type");} public int size(){throw new UnsupportedOperationException("Compile-only OpenXES type");} public XEvent get(int i){throw new UnsupportedOperationException("Compile-only OpenXES type");} }';
'XLog.java'='package org.deckfour.xes.model; public class XLog { public XLog(){throw new UnsupportedOperationException("Compile-only OpenXES type");} public int size(){throw new UnsupportedOperationException("Compile-only OpenXES type");} public XTrace get(int i){throw new UnsupportedOperationException("Compile-only OpenXES type");} }';
'XEventClassifier.java'='package org.deckfour.xes.classification; public class XEventClassifier { public XEventClassifier(){throw new UnsupportedOperationException("Compile-only OpenXES type");} public String getClassIdentity(org.deckfour.xes.model.XEvent e){throw new UnsupportedOperationException("Compile-only OpenXES type");} }'
}
foreach($name in $types.Keys){[IO.File]::WriteAllText((Join-Path $stub $name),$types[$name],[Text.UTF8Encoding]::new($false))}
$javac=Join-Path $JdkHome 'bin/javac.exe'
$sources=@((Join-Path $private 'LogParser.java'),(Join-Path $private 'SimpleLog.java'),(Join-Path $PSScriptRoot 'LegacyHarness.java'))+@(Get-ChildItem $stub -Filter '*.java'|ForEach-Object FullName)
& $javac -encoding UTF-8 -d $classes @sources 1> (Join-Path $build 'compile.stdout.log') 2> (Join-Path $build 'compile.stderr.log')
if($LASTEXITCODE -ne 0){throw "Reference compilation failed; inspect private logs"}
& (Join-Path $JdkHome 'bin/java.exe') -version 1> (Join-Path $build 'java-version.stdout.log') 2> (Join-Path $build 'java-version.stderr.log')
if($LASTEXITCODE -ne 0){throw 'Java version probe failed'}
Write-Output 'Unmodified actual reference classes compiled; XLog overload intentionally unavailable.'
Write-Output $classes
