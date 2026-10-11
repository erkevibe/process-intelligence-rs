import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {spawnSync} from 'node:child_process';
const [jdk,buildDir,corpusDir,outDir]=process.argv.slice(2);
if(!outDir||fs.existsSync(outDir))throw Error('Usage: JDK BUILD CORPUS NEW_OUTPUT; no overwrite');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const build=JSON.parse(fs.readFileSync(path.join(buildDir,'build-proof.json'),'utf8').replace(/^\uFEFF/,''));
const root=path.resolve(buildDir);
const verified=[];
for(const f of build.files??[]){
 if(f.status && f.status!=='captured')continue;
 const file=path.resolve(root,f.path);
 if(!file.startsWith(root+path.sep))throw Error('Build manifest escaped root');
 const bytes=fs.readFileSync(file);
 if(bytes.length!==f.bytes||sha(bytes)!==f.sha256.toLowerCase())throw Error('Build file identity changed: '+f.path);
 verified.push(f.path.replaceAll('\\','/'));
}
const executableInputs=[];
const walk=(dir,prefix)=>{for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,entry.name),relative=prefix+'/'+entry.name;if(entry.isSymbolicLink())throw Error('Reference symlink rejected');if(entry.isDirectory())walk(p,relative);else executableInputs.push(relative);}};
walk(path.join(buildDir,'classes'),'classes');
for(const x of fs.readdirSync(path.join(buildDir,'deps')))if(x.endsWith('.jar'))executableInputs.push('deps/'+x);
if(executableInputs.some(p=>!verified.includes(p)))throw Error('Executable reference input lacks captured hash');
const corpusBytes=fs.readFileSync(path.join(corpusDir,'corpus.json'));const corpus=JSON.parse(corpusBytes);
const jars=fs.readdirSync(path.join(buildDir,'deps')).filter(x=>x.endsWith('.jar')).map(x=>path.resolve(buildDir,'deps',x));
const classpath=[path.resolve(buildDir,'classes'),...jars].join(path.delimiter);
fs.mkdirSync(outDir,{recursive:true});
const javaVersion=spawnSync(path.join(jdk,'bin','java.exe'),['-version'],{windowsHide:true,timeout:10000,encoding:'utf8'});
fs.writeFileSync(path.join(outDir,'java-version.stdout.log'),javaVersion.stdout??'');fs.writeFileSync(path.join(outDir,'java-version.stderr.log'),javaVersion.stderr??'');
if(javaVersion.error||javaVersion.status!==0||!(javaVersion.stderr??'').includes('11.0.32.1'))throw Error('Pinned Java11 runtime not verified');
const harness=path.resolve('tools/oracle/XesHarness.java');
const compile=spawnSync(path.join(jdk,'bin','javac.exe'),['-encoding','UTF-8','-cp',classpath,'-d',path.resolve(outDir),harness],{windowsHide:true,timeout:60000,encoding:'utf8',maxBuffer:16*1024*1024});
fs.writeFileSync(path.join(outDir,'harness-compile.stdout.log'),compile.stdout??'');fs.writeFileSync(path.join(outDir,'harness-compile.stderr.log'),compile.stderr??'');
if(compile.error||compile.status!==0)throw Error('Actual harness compilation failed; inspect captured logs');
const decode=s=>s==='-'?null:Buffer.from(s,'hex').toString('utf8');
const results=[];
for(const f of corpus.fixtures){
 const filename=path.resolve(corpusDir,f.id+'.xes'),bytes=fs.readFileSync(filename),inputSha=f.sha256??f.xes_sha256;if(sha(bytes)!==inputSha)throw Error('Frozen fixture identity mismatch');
 const started=new Date().toISOString();
 const run=spawnSync(path.join(jdk,'bin','java.exe'),['-Duser.timezone=UTC','-Dfile.encoding=UTF-8','-cp',path.resolve(outDir)+path.delimiter+classpath,'XesHarness',filename],{windowsHide:true,timeout:20000,encoding:'utf8',maxBuffer:16*1024*1024});
 fs.writeFileSync(path.join(outDir,f.id+'.stdout.log'),run.stdout??'');fs.writeFileSync(path.join(outDir,f.id+'.stderr.log'),run.stderr??'');
 const observed={name:null,cases:[],consumer:{variants:[]}};
 for(const line of (run.stdout??'').split(/\r?\n/)){
  const [type,...v]=line.split('\t');
  if(type==='log')observed.name=decode(v[0]);
  if(type==='trace')observed.cases[Number(v[0])]={name:decode(v[1]),events:[]};
  if(type==='event')observed.cases[Number(v[0])].events.push({ordinal:Number(v[1]),activity:decode(v[2]),timestamp_millis:v[3]==='-'?null:Number(v[3]),lifecycle:decode(v[4]),timestamp_attribute_type:v[5]==='-'?null:v[5],timestamp_attribute_value:decode(v[6])});
  if(type==='cases')observed.consumer.cases=Number(v[0]);
  if(type==='activities')observed.consumer.activities=Number(v[0]);
  if(type==='raw_total_events')observed.consumer.events=Number(v[0]);
  if(type==='variant')observed.consumer.variants.push({count:Number(v[0]),sequence:v[1]?v[1].split(',').map(decode):[]});
 }
 const exceptionClass=(run.stderr??'').match(/Exception in thread "main" ([\w.$]+)/)?.[1]??null;
 results.push({id:f.id,input_sha256:inputSha,started_at:started,ended_at:new Date().toISOString(),exit_code:run.status,signal:run.signal,launch_error:run.error?.code??null,status:run.status===0?'ok':'rejected',failure_kind:run.status===0?null:run.error?'process_failure':exceptionClass?'upstream_exception':'unclassified_process_failure',exception_class:exceptionClass,observed,stdout_sha256:sha(Buffer.from(run.stdout??'')),stderr_sha256:sha(Buffer.from(run.stderr??''))});
}
const report={schema_version:1,created_at:new Date().toISOString(),corpus_sha256:sha(corpusBytes),build_proof_sha256:sha(fs.readFileSync(path.join(buildDir,'build-proof.json'))),harness_sha256:sha(fs.readFileSync(harness)),verified_executable_inputs:executableInputs.length,java_executable_sha256:sha(fs.readFileSync(path.join(jdk,'bin','java.exe'))),javac_executable_sha256:sha(fs.readFileSync(path.join(jdk,'bin','javac.exe'))),reference_build:build,parameters:corpus.parameters,results};
fs.writeFileSync(path.join(outDir,'results.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({report:path.resolve(outDir,'results.json'),examples:results.length,successful:results.filter(x=>x.status==='ok').length,actual_rejections:results.filter(x=>x.status==='rejected').map(x=>x.id)}));
