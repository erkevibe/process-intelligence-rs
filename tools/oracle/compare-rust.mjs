// Runs ONLY a newly spawned ephemeral process, never an existing installation.
import fs from 'node:fs';import path from 'node:path';import net from 'node:net';import crypto from 'node:crypto';import {spawn} from 'node:child_process';
const [executable,referenceReport,outDir]=process.argv.slice(2);
if(!executable||!referenceReport||!outDir)throw Error('Usage: node compare-rust.mjs EXE REFERENCE_RESULTS_JSON NEW_PRIVATE_OUTPUT_DIR');
if(fs.existsSync(outDir))throw Error('Output directory exists; never overwrite evidence');fs.mkdirSync(outDir,{recursive:true});
const exe=path.resolve(executable);const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const corpus=JSON.parse(fs.readFileSync('fixtures/oracle/corpus.json','utf8'));const reference=JSON.parse(fs.readFileSync(referenceReport,'utf8'));
if(reference.corpus_sha256!==sha(fs.readFileSync('fixtures/oracle/corpus.json')))throw Error('Reference corpus identity mismatch');
const server=net.createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;await new Promise(r=>server.close(r));
if([3000,3010].includes(port))throw Error('Protected port');
const stdout=fs.openSync(path.join(outDir,'app.stdout.log'),'wx'),stderr=fs.openSync(path.join(outDir,'app.stderr.log'),'wx');
const child=spawn(exe,[],{env:{...process.env,PORT:String(port),PI_EPHEMERAL:'1'},windowsHide:true,stdio:['ignore',stdout,stderr]});
let spawnError;child.on('error',e=>spawnError=e);const base=`http://127.0.0.1:${port}`;
const request=(url,init={})=>fetch(base+url,{...init,signal:AbortSignal.timeout(10000)});
const sorted=arr=>JSON.stringify(arr.map(x=>JSON.stringify(x)).sort());
try{
 let ready=false;for(let i=0;i<100;i++){if(spawnError||child.exitCode!==null)throw Error('Own process did not start');try{const h=await request('/health');if(h.ok){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,100));}if(!ready)throw Error('Own process health timeout');
 const results=[];
 for(const f of corpus.fixtures){
  const bytes=fs.readFileSync(`fixtures/oracle/${f.id}.xes`);if(sha(bytes)!==f.xes_sha256)throw Error('Frozen fixture changed');
  const form=new FormData();form.append('file',new Blob([bytes],{type:'application/xml'}),f.id+'.xes');
  const response=await request('/logs',{method:'POST',headers:{Origin:base},body:form});const html=await response.text();fs.writeFileSync(path.join(outDir,f.id+'.upload.html'),html);
  if(!response.ok)throw Error(`Rust import failed ${f.id}: ${response.status}`);
  const matches=[...html.matchAll(/href="\/logs\/([^"/]+)\/export"/g)];if(matches.length!==1)throw Error('Ambiguous current log ID');const id=matches[0][1];
  const exported=await request(`/logs/${id}/export`);if(!exported.ok)throw Error('Rust export failed');const value=await exported.json();fs.writeFileSync(path.join(outDir,f.id+'.export.json'),JSON.stringify(value,null,2)+'\n');
  if(value.source_sha256!==f.xes_sha256)throw Error('Imported source identity changed');
  const a=value.analysis, labels=Object.fromEntries(a.nodes.map(n=>[n.id,n.label]));const variants=a.variants.map(v=>({sequence:v.sequence,count:v.count}));const edges=a.edges.map(e=>({source:labels[e.source],target:labels[e.target],count:e.count}));const activityCounts=Object.fromEntries(a.nodes.map(n=>[n.label,n.count]));
  const legacy=reference.results.find(r=>r.id===f.id);if(!legacy)throw Error('Missing actual reference example');
  const manual={cases:a.cases===f.expected.cases,events:a.events===f.expected.events,activities:a.activities===f.expected.activities,activity_counts:sorted(Object.entries(activityCounts))===sorted(Object.entries(f.expected.activity_counts)),variants:sorted(variants.map(v=>[v.sequence,v.count]))===sorted(f.expected.variants.map(v=>[v.sequence,v.count])),dfg:sorted(edges.map(e=>[e.source,e.target,e.count]))===sorted(f.expected.edges.map(e=>[e.source,e.target,e.count]))};
  const actualLegacy={cases:a.cases===legacy.cases,activities:a.activities===legacy.activities,variants:sorted(variants.map(v=>[v.sequence,v.count]))===sorted(legacy.variants.map(v=>[v.sequence,v.count]))};
  results.push({id:f.id,log_id:id,xes_sha256:f.xes_sha256,rust:{cases:a.cases,events:a.events,activities:a.activities,variants,edges,activity_counts:activityCounts},actual_legacy:legacy,manual_comparison:manual,legacy_comparison:actualLegacy,excluded:['legacy XES import','legacy timestamp normalization','legacy DFG miner','Portal','SplitMiner discovered BPMN quality']});
 }
 const report={created_at:new Date().toISOString(),rust_executable:exe,rust_executable_sha256:sha(fs.readFileSync(exe)),own_pid:child.pid,own_port:port,corpus_sha256:reference.corpus_sha256,reference_report_sha256:sha(fs.readFileSync(referenceReport)),parameters:corpus.parameters,results};fs.writeFileSync(path.join(outDir,'comparison.json'),JSON.stringify(report,null,2)+'\n');
 const passed=results.every(r=>[...Object.values(r.manual_comparison),...Object.values(r.legacy_comparison)].every(Boolean));console.log(JSON.stringify({passed,examples:results.length,report:path.resolve(outDir,'comparison.json'),own_pid:child.pid,own_port:port}));if(!passed)process.exitCode=1;
}finally{if(child.exitCode===null&&!spawnError){child.kill();await new Promise(r=>{child.once('exit',r);setTimeout(r,3000);});}fs.closeSync(stdout);fs.closeSync(stderr);}
