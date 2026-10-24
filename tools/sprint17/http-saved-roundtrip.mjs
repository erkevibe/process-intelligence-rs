// Finite API verification of actual browser-produced resources; no browser state access.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
const [configPath, phase] = process.argv.slice(2);
assert(['before','after','roundtrip'].includes(phase));
const config=JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^\uFEFF/,''));
const base='http://127.0.0.1:3106';
const out=path.resolve(config.output);
assert.equal(out,path.resolve('.local/sprint17/root/browser01'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
let cookie='';
async function request(route,options={}){
  const r=await fetch(base+route,{...options,redirect:'manual',signal:AbortSignal.timeout(5000),headers:{Origin:base,...(cookie?{Cookie:cookie}:{}),...options.headers}});
  const reader=r.body.getReader(),chunks=[];let size=0;
  try{for(;;){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>2*1024*1024)throw Error('response_cap');chunks.push(Buffer.from(value));}}finally{await reader.cancel();}
  return {response:r,body:Buffer.concat(chunks)};
}
const login=await request('/login',{method:'POST',body:new URLSearchParams({username:config.username,password:config.password}),headers:{'Content-Type':'application/x-www-form-urlencoded'}});
assert.equal(login.response.status,303);
cookie=login.response.headers.get('set-cookie')?.split(';')[0];assert(cookie?.startsWith('pi_session='));
const reports=[];
const routes=phase==='roundtrip' ? [['reimport-model','/models/model-3/json'],['reimport-bpmn','/models/model-3/export']] : [['source','/logs/log-1/original'],['model','/models/model-2/json'],['bpmn','/models/model-2/export'],['history','/logs/log-1/import-history'],...(phase==='after'?[['reimport-model','/models/model-3/json'],['reimport-bpmn','/models/model-3/export']]:[])];
const extension=name=>name.endsWith('bpmn')?'.bpmn':name==='source'?'.xes':'.json';
for(const [name,route] of routes){
  const {response,body}=await request(route);assert.equal(response.status,200);
  fs.writeFileSync(path.join(out,phase+'-'+name+extension(name)),body,{flag:'wx'});
  reports.push({name,route,status:response.status,bytes:body.length,sha256:sha(body)});
  if(name==='source')assert.equal(sha(body),'02f30140fa00c37fe667e555514076440c123e76f2dded1fca69067b73de234f');
  if(name==='model'){
    const value=JSON.parse(body);assert.equal(value.revision,2);assert.equal(value.model.nodes.length,4);assert.equal(value.model.flows.length,3);
    const a=value.model.nodes.find(n=>n.id==='a'),s=value.model.nodes.find(n=>n.id==='s');
    assert.deepEqual([a.label,a.x,a.y,a.dimensions.width,a.dimensions.height],['S16 edited & safe',150.5,90.25,100,80]);
    assert.deepEqual([s.x,s.y,s.dimensions.width,s.dimensions.height],[10.5,20,36,36]);
    assert.deepEqual(value.model.flows.find(f=>f.id==='ab').waypoints,[{x:250.5,y:130.5},{x:300.5,y:40}]);
  }
  if(name==='reimport-model'){
    const baseline=JSON.parse(fs.readFileSync(path.join(out,'before-model.json')));
    assert.deepEqual(JSON.parse(body).model,baseline.model,'full model semantic and DI roundtrip');
  }
  if(phase==='after'){
    const previous=fs.readFileSync(path.join(out,(name.startsWith('reimport-')?'roundtrip-':'before-')+name+extension(name)));
    assert.equal(sha(body),sha(previous),'exact preserved '+name);
  }
}
const result={status:'ACTUAL_HTTP_SAVED_RESOURCES_VERIFIED',phase,reports,no_browser_download_claim:true,no_browser_cookie_or_hidden_state_access:true};
fs.writeFileSync(path.join(out,phase+'-http-result.json'),JSON.stringify(result,null,2),{flag:'wx'});
console.log(JSON.stringify(result));
