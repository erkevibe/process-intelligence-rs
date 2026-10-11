import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const comparatorHash=sha(fs.readFileSync(process.argv[1]));
const [exe,reference,corpusDir,out]=process.argv.slice(2);
if(!out||fs.existsSync(out))throw Error('Fresh private output required');
if(!path.resolve(out).startsWith(path.resolve('.local/sprint07')+path.sep))throw Error('Private output must stay under protected sprint07');
const corpusBytes=fs.readFileSync(path.join(corpusDir,'corpus.json')),corpus=JSON.parse(corpusBytes),referenceBytes=fs.readFileSync(reference),ref=JSON.parse(referenceBytes);
assert.equal(ref.corpus_sha256,sha(corpusBytes));assert.equal(ref.results.length,corpus.fixtures.length);
assert.equal(new Set(ref.results.map(r=>r.id)).size,corpus.fixtures.length);
const exeHash=sha(fs.readFileSync(exe));fs.mkdirSync(out,{recursive:true});const results=[];
const pairs=a=>a.map(x=>[x.trace_index,x.event_index]);
for(const f of corpus.fixtures){
 const file=path.join(corpusDir,f.file);assert.equal(sha(fs.readFileSync(file)),f.sha256);assert.equal(sha(fs.readFileSync(exe)),exeHash);
 const r=ref.results.find(r=>r.id===f.id);assert.equal(r.input_sha256,f.sha256);
 const run=spawnSync(exe,[file],{encoding:'utf8',windowsHide:true,timeout:20000,maxBuffer:4*1024*1024});
 fs.writeFileSync(path.join(out,f.id+'.stdout.log'),run.stdout??'');fs.writeFileSync(path.join(out,f.id+'.stderr.log'),run.stderr??'');fs.writeFileSync(path.join(out,f.id+'.exit.json'),JSON.stringify({exit_code:run.status,signal:run.signal,launch_error:run.error?.code??null}));
 assert.equal(run.status,0);const rust=JSON.parse(run.stdout),e=f.expected;
 if(e.legacy_error){assert.equal(r.status,'rejected');assert.equal(r.exception_class,e.legacy_error);assert.equal(r.exit_code,1);}
 else{
  assert.equal(r.status,'ok');assert.equal(r.exit_code,0);assert.equal(r.same_log,true);
  assert.deepEqual(r.after,r.second);assert.equal(r.before.name,'Service corpus');assert.equal(r.after.name,r.before.name);
  for(const phase of ['before','after','second'])assert.deepEqual(r.counts[phase],{traces:r[phase].cases.length,events:r[phase].cases.reduce((n,c)=>n+c.events.length,0)});
  const original=new Map();for(const c of r.before.cases){assert(!original.has(c.trace_index));assert.equal(c.trace_index,original.size);const es=new Map();for(const v of c.events){assert.equal(v.event_index,es.size);es.set(v.event_index,v);}original.set(c.trace_index,{...c,events:es});}
  const traces=new Set();for(const c of r.after.cases){assert(!traces.has(c.trace_index));traces.add(c.trace_index);const before=original.get(c.trace_index);assert(before);assert.equal(c.name,before.name);assert(c.events.length>0);let prev=-1;for(const v of c.events){assert(v.event_index>prev);prev=v.event_index;const b=before.events.get(v.event_index);assert(b);assert.equal(v.activity,b.activity);assert.equal(v.timestamp_millis,b.timestamp_millis);assert.equal(v.timestamp_attribute_type,b.timestamp_attribute_type);assert.equal(v.timestamp_attribute_value,b.timestamp_attribute_value);assert.equal(v.activity_attribute_type,b.activity_attribute_type);assert.equal(v.lifecycle,b.lifecycle_attribute_type===null?'complete':b.lifecycle);assert.equal(v.lifecycle_attribute_type,b.lifecycle_attribute_type===null?'org.deckfour.xes.model.impl.XAttributeLiteralImpl':b.lifecycle_attribute_type);}}
 }
 if(e.rust_error){
  assert.equal(rust.status,'rejected');assert.equal(rust.error.code,e.rust_error);
  if(!e.legacy_error){assert.equal(r.before.cases.length,1);assert.equal(r.before.cases[0].events.length,1);
   if(f.id==='wrong-lifecycle-type'){assert.equal(r.after.cases.length,0);assert.deepEqual(pairs(r.actions.removed_events),[[0,0]]);assert.deepEqual(r.actions.removed_events[0].reasons,['unsupported_lifecycle']);}
   else{assert.equal(r.after.cases.length,1);assert.equal(r.after.cases[0].events.length,1);const v=r.after.cases[0].events[0];assert.equal(v.event_index,0);assert.equal(v.lifecycle,'complete');assert.equal(v.activity,({ 'empty-name':'','wrong-time-type':'A','wrong-name-type':'7','duplicate-name':'B'})[f.id]);assert.equal(v.timestamp_millis,f.id==='wrong-time-type'?null:1767261600000);assert.deepEqual(r.actions.removed_events,[]);}}
 }else{
  assert.equal(rust.status,'ok');const p=rust.preview;assert.equal(p.policy,'apromore-validateLog-bbf24df-preview-v1');assert.equal(p.log.name,'Service corpus');assert.equal(p.source_cases,e.source_cases);assert.equal(p.source_events,e.source_events);assert.equal(p.fully_filtered,e.cases.length===0);
  assert.equal(r.before.cases.length,e.source_cases);assert.equal(r.before.cases.reduce((n,c)=>n+c.events.length,0),e.source_events);
  assert.equal(p.log.cases.length,e.cases.length);assert.equal(r.after.cases.length,e.cases.length);
  for(let i=0;i<e.cases.length;i++){const x=e.cases[i],c=p.log.cases[i],j=r.after.cases[i];assert.equal(c.id,'case-'+x.index);assert.equal(c.name,x.name);assert.equal(j.trace_index,x.index);assert.equal(j.name,x.name);assert.equal(c.events.length,x.events.length);assert.equal(j.events.length,x.events.length);for(let k=0;k<x.events.length;k++){const y=x.events[k],v=c.events[k],w=j.events[k];assert.equal(v.ordinal,y.index);assert.equal(w.event_index,y.index);assert.equal(v.activity,y.activity);assert.equal(w.activity,y.activity);assert.equal(v.lifecycle,y.lifecycle);assert.equal(w.lifecycle,y.lifecycle);assert.equal(v.timestamp,y.time);assert.equal(w.timestamp_millis,Date.parse(y.time));}}
  assert.deepEqual(p.changes.filter(c=>c.action==='default_lifecycle').map(c=>[c.case_index,c.event_index]),e.defaulted);assert.deepEqual(p.changes.filter(c=>c.action==='remove_event').map(c=>[c.case_index,c.event_index,c.reasons]),e.removed);assert.deepEqual(p.changes.filter(c=>c.action==='remove_case').map(c=>c.case_index),e.removed_cases);
  assert.deepEqual(pairs(r.actions.defaulted_lifecycle),e.defaulted);assert.deepEqual(r.actions.removed_events.map(c=>[c.trace_index,c.event_index,c.reasons.map(x=>x==='missing_name'?'missing_activity':x)]),e.removed);assert.deepEqual(r.actions.removed_traces.map(c=>c.trace_index),e.removed_cases);
  assert.equal(p.changes.length,e.defaulted.length+e.removed.length+e.removed_cases.length);
  for(const c of p.changes){if(c.action==='default_lifecycle')assert.deepEqual(c.reasons,['missing_lifecycle']);if(c.action==='remove_case'){assert.equal(c.event_index,null);assert.deepEqual(c.reasons,['empty_case']);}}
 }
 results.push({id:f.id,manual_pass:true,compatibility:e.rust_error?'explicit-admission-divergence':'supported-policy-equality',rust,legacy:r});
}
assert.equal(sha(fs.readFileSync(exe)),exeHash);
assert.equal(sha(fs.readFileSync(process.argv[1])),comparatorHash);
const report={schema:1,scope:'Extracted unchanged methods only; strict Rust admission divergences; no whole service parity',comparator_sha256:comparatorHash,corpus_sha256:sha(corpusBytes),reference_sha256:sha(referenceBytes),observer_exe_sha256:exeHash,results};
fs.writeFileSync(path.join(out,'comparison.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({manual_pass:results.length,supported:results.filter(r=>r.compatibility==='supported-policy-equality').length,divergences:results.filter(r=>r.compatibility!=='supported-policy-equality').length}));
