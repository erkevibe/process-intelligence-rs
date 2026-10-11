import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const ownDir=path.dirname(fileURLToPath(import.meta.url));
export function extractMethods(bytes,lock){
  const blob=crypto.createHash('sha1').update(Buffer.from('blob '+bytes.length+'\0')).update(bytes).digest('hex');
  if(bytes.length!==lock.bytes||sha(bytes)!==lock.sha256||blob!==lock.git_blob)throw Error('Pinned service source identity mismatch');
  const start=Buffer.from('    public static XLog validateLog(XLog log) {');
  const end=Buffer.from('    @Override');
  const a=bytes.indexOf(start),z=bytes.indexOf(end,a);
  if(a!==lock.methods_offset||z-a!==lock.methods_bytes||bytes.indexOf(start,a+1)!==-1)throw Error('Method extraction boundary mismatch');
  const methods=bytes.subarray(a,z);
  if(sha(methods)!==lock.methods_sha256||!methods.includes(Buffer.from('    private static boolean isInvalidEvent(XEvent event) {')))throw Error('Method byte identity mismatch');
  const prefix=Buffer.from('import java.util.*;\nimport org.deckfour.xes.model.*;\nimport org.deckfour.xes.model.impl.XAttributeLiteralImpl;\npublic final class ExtractedServiceMethods {\n');
  return {methods,generated:Buffer.concat([prefix,methods,Buffer.from('}\n')]),offset:a,bytes:methods.length,sha256:sha(methods)};
}
export function verifyBuild(buildDir){
  const root=fs.realpathSync(buildDir),proofBytes=fs.readFileSync(path.join(root,'build-proof.json'));
  const proof=JSON.parse(proofBytes.toString('utf8').replace(/^\uFEFF/,'')),verified=new Set();
  for(const f of proof.files??[]){
    if(f.status&&f.status!=='captured')throw Error('Uncaptured base build input');
    const file=path.resolve(root,f.path);
    if(!file.startsWith(root+path.sep)||fs.realpathSync(file)!==file)throw Error('Base manifest escape or symlink');
    const b=fs.readFileSync(file);
    if(b.length!==f.bytes||sha(b)!==f.sha256.toLowerCase())throw Error('Base build identity changed: '+f.path);
    verified.add(f.path.replaceAll('\\','/'));
  }
  const executable=[];
  function walk(dir,rel){for(const e of fs.readdirSync(dir,{withFileTypes:true})){if(e.isSymbolicLink())throw Error('Base executable symlink');const r=rel+'/'+e.name,p=path.join(dir,e.name);if(e.isDirectory())walk(p,r);else executable.push(r);}}
  walk(path.join(root,'classes'),'classes');
  for(const e of fs.readdirSync(path.join(root,'deps'),{withFileTypes:true})){
    if(e.isSymbolicLink())throw Error('Base dependency symlink');
    if(e.name.endsWith('.jar')){if(!e.isFile())throw Error('Invalid dependency');executable.push('deps/'+e.name);}
  }
  if(!executable.length||executable.some(f=>!verified.has(f)))throw Error('Executable input lacks captured identity');
  return {proof,proof_sha256:sha(proofBytes),root,executable_inputs:executable.length,classpath:[path.join(root,'classes'),...executable.filter(f=>f.endsWith('.jar')).map(f=>path.join(root,f))].join(path.delimiter)};
}
export function verifyFreshClasses(outDir,classes){
  const expected=new Map(classes.map(c=>[c.path,c.sha256]));
  const seen=[];
  function walk(dir,rel=''){for(const e of fs.readdirSync(dir,{withFileTypes:true})){
    if(e.isSymbolicLink())throw Error('Fresh output symlink rejected');
    const p=path.join(dir,e.name),r=rel+e.name;
    if(e.isDirectory())walk(p,r+'/');
    else if(e.name.endsWith('.class')||e.name.endsWith('.jar')){
      if(!expected.has(r)||sha(fs.readFileSync(p))!==expected.get(r))throw Error('Fresh executable identity mismatch');seen.push(r);
    }
  }}
  walk(outDir);if(seen.length!==expected.size)throw Error('Fresh executable missing');
}
const decode=s=>s==='-'?null:Buffer.from(s,'hex').toString('utf8');
export function parseObservation(stdout){
  const phases={before:{name:null,cases:[]},after:{name:null,cases:[]},second:{name:null,cases:[]}};
  let same_log=null;
  for(const line of stdout.split(/\r?\n/)){
    const [kind,phase,...v]=line.split('\t');
    if(kind==='same_log'){same_log=phase==='true';continue;}
    const target=phases[phase];if(!target)continue;
    if(kind==='log')target.name=decode(v[0]);
    if(kind==='trace')target.cases.push({trace_index:Number(v[0]),name:decode(v[1]),events:[]});
    if(kind==='event'){
      const c=target.cases.find(c=>c.trace_index===Number(v[0]));if(!c)throw Error('Event without observed trace');
      c.events.push({event_index:Number(v[1]),activity:decode(v[2]),lifecycle:decode(v[3]),timestamp_millis:v[4]==='-'?null:Number(v[4]),timestamp_attribute_type:v[5]==='-'?null:v[5],timestamp_attribute_value:decode(v[6]),activity_attribute_type:v[7]==='-'?null:v[7],lifecycle_attribute_type:v[8]==='-'?null:v[8]});
    }
  }
  const actions={defaulted_lifecycle:[],removed_events:[],removed_traces:[]};
  for(const c of phases.before.cases){
    const after=phases.after.cases.find(x=>x.trace_index===c.trace_index);
    for(const e of c.events){
      const id={trace_index:c.trace_index,event_index:e.event_index};
      if(e.lifecycle_attribute_type===null)actions.defaulted_lifecycle.push(id);
      if(!after?.events.some(x=>x.event_index===e.event_index)){
        const reasons=[];
        if(e.activity_attribute_type===null)reasons.push('missing_name');
        if(e.timestamp_attribute_type===null)reasons.push('missing_timestamp');
        if(e.lifecycle_attribute_type!==null&&!['start','complete'].includes(e.lifecycle?.toLowerCase()))reasons.push('unsupported_lifecycle');
        actions.removed_events.push({...id,reasons});
      }
    }
    if(!after)actions.removed_traces.push({trace_index:c.trace_index,reason:'empty_trace'});
  }
  const counts=Object.fromEntries(Object.entries(phases).map(([k,v])=>[k,{traces:v.cases.length,events:v.cases.reduce((n,c)=>n+c.events.length,0)}]));
  return {...phases,actions,counts,same_log,idempotent:JSON.stringify(phases.after)===JSON.stringify(phases.second)};
}
export async function runReference(jdk,buildDir,corpusDir,outDir){
  if(!outDir||fs.existsSync(outDir))throw Error('Usage: JDK BASE_BUILD CORPUS NEW_OUTPUT; never overwrite');
  const allowed=path.resolve('.local/sprint07');
  if(!path.resolve(outDir).startsWith(allowed+path.sep))throw Error('Private output must remain under protected .local/sprint07');
  const base=verifyBuild(buildDir),lockBytes=fs.readFileSync(path.join(ownDir,'service-source.lock.json')),lock=JSON.parse(lockBytes);
  if(base.proof.source_commit!==lock.commit||base.proof.tree_sha!==lock.tree_sha)throw Error('Base source commit/tree mismatch');
  const tree=JSON.parse(fs.readFileSync(path.join(base.root,'provenance/tree.json')));
  if(tree.sha!==lock.tree_sha||tree.truncated!==false||tree.tree.find(x=>x.path===lock.path)?.sha!==lock.git_blob)throw Error('Pinned source tree identity mismatch');
  const corpusBytes=fs.readFileSync(path.join(corpusDir,'corpus.json')),corpus=JSON.parse(corpusBytes);
  for(const f of corpus.fixtures){if(!/^[a-z0-9-]+$/.test(f.id)||sha(fs.readFileSync(path.join(corpusDir,f.id+'.xes')))!==(f.sha256??f.xes_sha256))throw Error('Frozen fixture identity mismatch');}
  fs.mkdirSync(outDir,{recursive:true});
  const javaFile=path.join(jdk,'bin/java.exe'),javacFile=path.join(jdk,'bin/javac.exe');
  const javaSha=sha(fs.readFileSync(javaFile)),javacSha=sha(fs.readFileSync(javacFile));
  const verifyJdk=()=>{if(sha(fs.readFileSync(javaFile))!==javaSha||sha(fs.readFileSync(javacFile))!==javacSha)throw Error('JDK executable identity changed');};
  fs.writeFileSync(path.join(outDir,'jdk-inputs.json'),JSON.stringify({java_sha256:javaSha,javac_sha256:javacSha,scope:'Before version and compile; checked before each invocation and after loop. Full official distribution verification is separate independent QA.'})+'\n',{flag:'wx'});
  const capture=(name,exe,args,timeout=60000)=>{
    const start=new Date().toISOString(),r=spawnSync(exe,args,{windowsHide:true,timeout,encoding:'utf8',maxBuffer:16*1024*1024});
    fs.writeFileSync(path.join(outDir,name+'.stdout.log'),r.stdout??'',{flag:'wx'});fs.writeFileSync(path.join(outDir,name+'.stderr.log'),r.stderr??'',{flag:'wx'});
    fs.writeFileSync(path.join(outDir,name+'.exit.json'),JSON.stringify({start,end:new Date().toISOString(),pid:r.pid??null,exe_path:path.resolve(exe),exe_sha256:sha(fs.readFileSync(exe)),arguments:args,exit_code:r.status,signal:r.signal,launch_error:r.error?.code??null})+'\n',{flag:'wx'});return r;
  };
  const version=capture('java-version',path.join(jdk,'bin/java.exe'),['-version'],10000);
  if(version.status!==0||!version.stderr?.includes('11.0.32.1'))throw Error('Pinned Java version mismatch');
  const url='https://raw.githubusercontent.com/apromore/ApromoreCore/'+lock.commit+'/'+lock.path;
  const fetchStart=new Date().toISOString();let source;
  try{
    const fetched=await fetch(url,{signal:AbortSignal.timeout(60000)});if(!fetched.ok)throw Error('Pinned service source fetch failed: '+fetched.status);
    source=Buffer.from(await fetched.arrayBuffer());
    fs.writeFileSync(path.join(outDir,'fetch.exit.json'),JSON.stringify({start:fetchStart,end:new Date().toISOString(),status:'captured',http_status:fetched.status,bytes:source.length,sha256:sha(source)})+'\n',{flag:'wx'});
    fs.writeFileSync(path.join(outDir,'fetch.stdout.log'),'Pinned service source fetched; byte/hash identity verification follows.\n',{flag:'wx'});fs.writeFileSync(path.join(outDir,'fetch.stderr.log'),'',{flag:'wx'});
  }catch(e){fs.writeFileSync(path.join(outDir,'fetch.exit.json'),JSON.stringify({start:fetchStart,end:new Date().toISOString(),status:'failed',error_code:e.code??e.name})+'\n',{flag:'wx'});fs.writeFileSync(path.join(outDir,'fetch.stderr.log'),String(e)+'\n',{flag:'wx'});throw e;}
  fs.writeFileSync(path.join(outDir,'EventLogServiceImpl.java'),source,{flag:'wx'});
  const extracted=extractMethods(source,lock);fs.writeFileSync(path.join(outDir,'ExtractedServiceMethods.java'),extracted.generated,{flag:'wx'});
  fs.writeFileSync(path.join(outDir,'extraction.json'),JSON.stringify({source_sha256:sha(source),source_git_blob:lock.git_blob,offset:extracted.offset,bytes:extracted.bytes,methods_sha256:extracted.sha256,envelope_sha256:sha(extracted.generated),scope:lock.scope})+'\n',{flag:'wx'});
  verifyJdk();
  const harness=path.join(ownDir,'service-harness.java'),harnessSha=sha(fs.readFileSync(harness));
  const compile=capture('compile',javacFile,['-encoding','UTF-8','-cp',base.classpath,'-d',path.resolve(outDir),path.resolve(outDir,'ExtractedServiceMethods.java'),harness]);
  if(compile.status!==0)throw Error('Extracted methods compile failed; preserve logs');
  const classFiles=['ExtractedServiceMethods.class','ServiceHarness.class'].map(p=>({path:p,sha256:sha(fs.readFileSync(path.join(outDir,p)))}));
  const results=[];
  for(const f of corpus.fixtures){
    // Revalidate every executable before each invocation; adapter never changes the log.
    verifyBuild(buildDir);verifyJdk();verifyFreshClasses(outDir,classFiles);
    if(sha(fs.readFileSync(path.join(corpusDir,f.id+'.xes')))!==(f.sha256??f.xes_sha256))throw Error('Fixture changed before invocation');
    const run=capture(f.id,path.join(jdk,'bin/java.exe'),['-Duser.timezone=UTC','-Dfile.encoding=UTF-8','-cp',path.resolve(outDir)+path.delimiter+base.classpath,'ServiceHarness',path.resolve(corpusDir,f.id+'.xes')],20000);
    const errorClass=run.stderr?.match(/Exception in thread "main" ([\w.$]+)/)?.[1]??null;
    results.push({id:f.id,input_sha256:f.sha256??f.xes_sha256,status:run.status===0?'ok':'rejected',exit_code:run.status,launch_error:run.error?.code??null,exception_class:errorClass,...(run.status===0?parseObservation(run.stdout):{}),stdout_sha256:sha(Buffer.from(run.stdout??'')),stderr_sha256:sha(Buffer.from(run.stderr??''))});
  }
  verifyJdk();verifyFreshClasses(outDir,classFiles);
  if(sha(fs.readFileSync(harness))!==harnessSha||sha(fs.readFileSync(path.join(corpusDir,'corpus.json')))!==sha(corpusBytes))throw Error('Harness or corpus changed during execution');
  const report={schema_version:1,scope:lock.scope,created_at:new Date().toISOString(),corpus_sha256:sha(corpusBytes),source_lock_sha256:sha(lockBytes),base_build_proof_sha256:base.proof_sha256,verified_executable_inputs:base.executable_inputs,source_sha256:sha(source),methods_sha256:extracted.sha256,envelope_sha256:sha(extracted.generated),harness_sha256:harnessSha,class_files:classFiles,java_executable_sha256:javaSha,javac_executable_sha256:javacSha,results};
  fs.writeFileSync(path.join(outDir,'results.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx'});
  console.log(JSON.stringify({examples:results.length,success:results.filter(x=>x.status==='ok').length,scope:lock.scope}));
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))runReference(...process.argv.slice(2)).catch(e=>{console.error(e.stack);process.exitCode=1;});
