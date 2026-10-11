param([Parameter(Mandatory=$true)][string]$JdkHome,[string]$PrivateDir='.local/sprint06/reference',[string]$Attempt='build-01',[Parameter(Mandatory=$true)][string]$NodePath)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $root
if($Attempt -notmatch '^build-[a-z0-9-]+$'){throw 'Invalid build attempt'}
$private=[IO.Path]::GetFullPath((Join-Path $root $PrivateDir))
$allowed=[IO.Path]::GetFullPath((Join-Path $root '.local/sprint06/reference'))
if($private -ne $allowed -and -not $private.StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Private reference must remain scoped'}
$build=Join-Path $private $Attempt
if(Test-Path $build){throw 'Never overwrite an attempt'}
New-Item -ItemType Directory -Force $private | Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$aclOutput = & icacls $private /inheritance:r /grant:r "*${sid}:(OI)(CI)F" /Q 2>&1
if($LASTEXITCODE -ne 0){throw 'Private ACL failed'}
New-Item -ItemType Directory $build | Out-Null
[IO.File]::WriteAllText((Join-Path $build 'acl.output.log'),($aclOutput -join [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
$fetch=@'
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const root=process.argv[2], out=process.argv[3]; const commit='bbf24dfd43e72d6992392465f875a4367cbe792b';
const lockBytes=fs.readFileSync(path.join(root,'tools/oracle/xes-reference.lock.json'));const lock=JSON.parse(lockBytes);
const manifest=[],sha=b=>crypto.createHash('sha256').update(b).digest('hex');
async function request(url){const r=await fetch(url,{signal:AbortSignal.timeout(60000),headers:{'User-Agent':'process-intelligence-oracle'}});if(!r.ok)throw Error(r.status+' '+url);return Buffer.from(await r.arrayBuffer());}
async function get(x){if(path.isAbsolute(x.file)||x.file.split(/[\\/]/).includes('..'))throw Error('Unsafe lock path');const b=await request(x.url);if(b.length!==x.bytes||sha(b).toUpperCase()!==x.sha256.toUpperCase())throw Error('Locked SHA256/size mismatch '+x.file);if(x.git_blob){const h=crypto.createHash('sha1').update(Buffer.from('blob '+b.length+'\0')).update(b).digest('hex');if(h!==x.git_blob)throw Error('Git blob mismatch '+x.file);}const file=path.join(out,x.file);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,b);manifest.push({...x,sha256:sha(b)});console.log('verified',x.file,b.length);}
(async()=>{const commitBytes=await request('https://api.github.com/repos/apromore/ApromoreCore/git/commits/'+lock.commit);const c=JSON.parse(commitBytes);if(c.sha!==lock.commit||c.tree.sha!==lock.tree_sha)throw Error('Pinned commit/tree mismatch');fs.mkdirSync(path.join(out,'provenance'),{recursive:true});fs.writeFileSync(path.join(out,'provenance/commit.json'),commitBytes);const treeBytes=await request('https://api.github.com/repos/apromore/ApromoreCore/git/trees/'+lock.tree_sha+'?recursive=1');const t=JSON.parse(treeBytes);if(t.sha!==lock.tree_sha||t.truncated!==false)throw Error('Tree incomplete or wrong');fs.writeFileSync(path.join(out,'provenance/tree.json'),treeBytes);
for(const x of lock.files.filter(x=>x.git_blob)){const upstream=x.url.split('/'+lock.commit+'/')[1];const blob=t.tree.find(p=>p.path===upstream);if(!blob||blob.sha!==x.git_blob)throw Error('Tree source identity mismatch '+x.file);}
let next=0;async function worker(){while(next<lock.files.length)await get(lock.files[next++]);}await Promise.all(Array.from({length:8},worker));fs.writeFileSync(path.join(out,'fetch-manifest.json'),JSON.stringify({schema_version:1,commit:lock.commit,tree_sha:lock.tree_sha,lock_sha256:sha(lockBytes),dependencies:lock.dependencies,dependency_licenses:lock.dependency_licenses,files:manifest},null,2)+'\n');})().catch(e=>{console.error(e.stack);process.exitCode=1});
'@
[IO.File]::WriteAllText((Join-Path $build 'fetch.cjs'),$fetch,[Text.UTF8Encoding]::new($false))
& $NodePath (Join-Path $build 'fetch.cjs') $root $build 1> (Join-Path $build 'fetch.stdout.log') 2> (Join-Path $build 'fetch.stderr.log')
$fetchExit=$LASTEXITCODE
[IO.File]::WriteAllText((Join-Path $build 'fetch-exit.json'),"{`"exit`":$fetchExit}")
if($fetchExit -ne 0){throw 'Fetch failed; preserve logs'}
$probe=@'
import java.io.*;
import org.deckfour.xes.in.XesXmlParser;
import org.deckfour.xes.factory.XFactoryNaiveImpl;
import org.deckfour.xes.model.*;
import org.deckfour.xes.classification.XEventNameClassifier;
import org.apromore.splitminer.log.LogParser;
public class XesProbe {
 public static void main(String[] args)throws Exception {
  XLog log=new XesXmlParser(new XFactoryNaiveImpl()).parse(new FileInputStream(args[0])).get(0);
  System.out.println("traces="+log.size());
  System.out.println("events="+log.get(0).size());
  System.out.println("variants="+LogParser.getSimpleLog(log,new XEventNameClassifier()).getTraces());
 }
}
'@
[IO.File]::WriteAllText((Join-Path $build 'XesProbe.java'),$probe,[Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory (Join-Path $build 'classes') | Out-Null
$classpath=((Get-ChildItem (Join-Path $build 'deps') -Filter '*.jar').FullName -join ';')
& (Join-Path $JdkHome 'bin/javac.exe') -encoding UTF-8 -cp $classpath -sourcepath (Join-Path $build 'src') -d (Join-Path $build 'classes') (Join-Path $build 'XesProbe.java') 1> (Join-Path $build 'compile.stdout.log') 2> (Join-Path $build 'compile.stderr.log')
$compileExit=$LASTEXITCODE
[IO.File]::WriteAllText((Join-Path $build 'compile-exit.json'),"{`"exit`":$compileExit}")
if($compileExit -ne 0){throw 'Real source closure compilation failed; preserve diagnostics'}
& (Join-Path $JdkHome 'bin/java.exe') -version 1> (Join-Path $build 'java-version.stdout.log') 2> (Join-Path $build 'java-version.stderr.log')
$versionExit=$LASTEXITCODE
[IO.File]::WriteAllText((Join-Path $build 'java-version-exit.json'),"{`"exit`":$versionExit}")
if($versionExit -ne 0){throw 'Java version probe failed'}
$xml='<log><trace><string key="concept:name" value="probe"/><event><string key="concept:name" value="A"/><date key="time:timestamp" value="2026-01-01T00:00:00Z"/></event><event><string key="concept:name" value="B"/><date key="time:timestamp" value="2026-01-01T01:00:00+01:00"/></event></trace></log>'
[IO.File]::WriteAllText((Join-Path $build 'probe.xes'),$xml,[Text.UTF8Encoding]::new($false))
& (Join-Path $JdkHome 'bin/java.exe') '-Duser.timezone=UTC' '-Dfile.encoding=UTF-8' -cp ((Join-Path $build 'classes')+';'+$classpath) XesProbe (Join-Path $build 'probe.xes') 1> (Join-Path $build 'probe.stdout.log') 2> (Join-Path $build 'probe.stderr.log')
$probeExit=$LASTEXITCODE
[IO.File]::WriteAllText((Join-Path $build 'probe-exit.json'),"{`"exit`":$probeExit}")
if($probeExit -ne 0){throw 'Genuine parser/XLog probe failed'}
$observed=Get-Content -Raw (Join-Path $build 'probe.stdout.log')
if($observed -notmatch 'traces=1' -or $observed -notmatch 'events=2' -or $observed -notmatch 'variants='){throw 'Probe observations missing'}
$manifest=Get-Content -Raw (Join-Path $build 'fetch-manifest.json') | ConvertFrom-Json
$files=@(Get-ChildItem $build -Recurse -File | ForEach-Object {@{path=$_.FullName.Substring($build.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash}})
$proof=@{schema_version=1;source_commit=$manifest.commit;tree_sha=$manifest.tree_sha;lock_sha256=$manifest.lock_sha256;fetch_exit=$fetchExit;compile_exit=$compileExit;probe_exit=$probeExit;version_exit=$versionExit;java_version=(Get-Content -Raw (Join-Path $build 'java-version.stderr.log'));parser='org.deckfour.xes.in.XesXmlParser';factory='org.deckfour.xes.factory.XFactoryNaiveImpl';consumer='org.apromore.splitminer.log.LogParser.getSimpleLog(XLog,XEventNameClassifier)';compiled_classes=@(Get-ChildItem (Join-Path $build classes) -Recurse -Filter '*.class').Count;dependency_licenses=$manifest.dependency_licenses;files=$files;scope='Unchanged pinned genuine selective source closure. Probe only, no corpus or Portal acceptance. No stubs; classes/jars remain private outside MIT runtime.'}
[IO.File]::WriteAllText((Join-Path $build 'build-proof.json'),($proof|ConvertTo-Json -Depth 10)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
Write-Output 'Genuine cold reference build and parser/XLog probe succeeded.'
Write-Output $build
