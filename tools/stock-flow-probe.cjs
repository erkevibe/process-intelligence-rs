'use strict';
// Private finite HTTP fixture. No browser/Datastar interaction claim.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {ownedHttp}=require('./owned-http-client.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),mode=process.argv[3];
const root=cfg.output_directory,base='http://127.0.0.1:3095';
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const write=(name,data)=>fs.writeFileSync(path.join(root,name),data,{flag:'wx'});
const statePath=path.join(root,'http-private-state.json');
let state=mode==='seed'?{actors:{},logs:{}}:JSON.parse(fs.readFileSync(statePath,'utf8'));
let counter=0,records=[];
async function request(actor,route,method='GET',body,expected=200,origin=base){
 assert.match(route,/^\/[a-zA-Z0-9/_.-]*$/);assert.ok(!route.includes('..'));assert.ok(['GET','POST'].includes(method));
 let headers={};if(method==='POST')headers.Origin=origin;
 if(actor&&state.actors[actor]?.cookie)headers.Cookie=state.actors[actor].cookie;
 if(body instanceof URLSearchParams)headers['Content-Type']='application/x-www-form-urlencoded';
 const r=await ownedHttp({port:3095,route,method,body,headers});
 const bytes=r.bytes,text=bytes.toString('utf8');
 const label=mode+'-'+String(++counter).padStart(3,'0');
 write(label+'.body',bytes);
 const cookies=r.headers['set-cookie'];assert.ok(!cookies||cookies.length===1);
 const cookie=cookies?.[0];
 if(cookie&&actor){assert.match(cookie,/^pi_session=/);state.actors[actor].cookie=cookie.split(';')[0];}
 const record={route,method,status:r.status,expected,location:r.headers.location||null,bytes:bytes.length,sha256:hash(bytes),body_file:label+'.body'};
 records.push(record);write(label+'.json',JSON.stringify(record,null,2));
 assert.equal(r.status,expected,method+' '+route);
 return {text,bytes,location:record.location,cookie,json:()=>JSON.parse(text)};
}
const form=values=>new URLSearchParams(values);
const token=text=>{let m=text.match(/name="token"[^>]*value="([a-f0-9-]+)"/);assert.ok(m,'actual preview token');return m[1];};
async function login(actor){const a=state.actors[actor];const r=await request(actor,'/login','POST',form({username:a.username,password:a.password}),303);assert.equal(r.location,'/projects');}
async function open(actor){assert.equal((await request(actor,'/projects/'+state.project+'/open','POST',form({}),303)).location,'/logs');}
async function exportLog(actor,id){return (await request(actor,'/logs/'+id+'/export')).bytes;}
function counts(bytes,source){
 const j=JSON.parse(bytes);assert.equal(j.schema_version,1);assert.equal(j.source_sha256,source.toLowerCase());assert.equal(j.analysis.cases,2);assert.equal(j.analysis.events,5);assert.equal(j.analysis.activities,3);assert.equal(j.parameters.order,'source');assert.equal(j.parameters.lifecycle,'each-event');
 const labels=new Map(j.analysis.nodes.map(n=>[n.id,n.label]));
 assert.deepEqual(j.analysis.edges.map(e=>[labels.get(e.source),labels.get(e.target),e.count]).sort(),[['A','B',1],['A','C',1],['C','B',1]]);
 assert.deepEqual(j.analysis.variants.map(v=>[v.sequence.join(''),v.count]).sort(),[['AB',1],['ACB',1]]);
 return j;
}
function multipart(file,fields={}){const f=new FormData();f.set('file',new Blob([fs.readFileSync(file)]),path.basename(file));for(const[k,v]of Object.entries(fields))f.set(k,v);return f;}
async function main(){
 if(mode==='seed'){
  const secrets=JSON.parse(fs.readFileSync(cfg.credentials,'utf8'));
  for(const[k,v]of Object.entries(secrets))state.actors[k]={...v};
  const health=(await request(null,'/health')).json();assert.equal(health.version,'0.7.2');
  const setupPage=(await request(null,'/setup')).text;
  assert.ok(setupPage.includes('Создать первую учётную запись'));assert.ok(setupPage.includes('action="/setup"'));assert.ok(setupPage.includes('name="username"'));assert.ok(setupPage.includes('name="password"'));
  for(const asset of cfg.assets){const r=await request(null,asset.route);assert.equal(hash(r.bytes),asset.sha256.toLowerCase());}
  const owner=state.actors.owner;
  const setup=await request('owner','/setup','POST',form({username:owner.username,password:owner.password}),303);
  assert.equal(setup.location,'/projects');assert.match(setup.cookie,/HttpOnly/i);assert.match(setup.cookie,/SameSite=Strict/i);
  await request('owner','/projects','POST',form({name:cfg.project_name}),303);
  const projects=(await request('owner','/projects')).text;
  const rows=[...projects.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/g)].map(m=>m[1]).filter(r=>r.includes(cfg.project_name)&&/action="\/projects\/project-[a-z0-9]+\/open"/.test(r));
  assert.equal(rows.length,1,'exact named project row');
  const selected=rows[0].match(/action="\/projects\/(project-[a-z0-9]+)\/open"/);assert.ok(selected);state.project=selected[1];await open('owner');
  const preview=await request('owner','/xes/preview','POST',multipart(cfg.xes),200);
  const t=token(preview.text);state.preview_token=t;
  const report=(await request('owner','/xes/previews/'+t+'/report')).json();
  assert.equal(report.policy,'apromore-validateLog-bbf24df-preview-v1');assert.equal(report.source_cases,2);assert.equal(report.source_events,5);assert.equal(report.source_sha256,cfg.xes_sha.toLowerCase());assert.deepEqual(report.changes,[]);
  const imported=await request('owner','/xes/import','POST',form({token:t,consent:'yes'}),303);
  assert.match(imported.location,/^\/logs\/[a-z0-9-]+$/);state.logs.xes=imported.location.split('/').pop();
  const x=await exportLog('owner',state.logs.xes);counts(x,cfg.xes_sha);write('baseline-xes-export.json',x);
  const original=(await request('owner','/logs/'+state.logs.xes+'/original')).bytes;
  assert.equal(hash(original),cfg.xes_sha.toLowerCase());assert.deepEqual(original,fs.readFileSync(cfg.xes));write('baseline-xes-original.xes',original);
  const history=(await request('owner','/logs/'+state.logs.xes+'/import-history')).bytes;
  const h=JSON.parse(history);assert.equal(h.operation_id,t);assert.equal(h.policy,report.policy);assert.equal(h.source_sha256,cfg.xes_sha.toLowerCase());assert.equal(h.origin_project_id,state.project);assert.equal(h.source_cases,2);assert.equal(h.source_events,5);assert.deepEqual(h.actions,[]);assert.ok(!Number.isNaN(Date.parse(h.confirmed_at)));write('baseline-xes-history.json',history);
  const csv=await request('owner','/csv/preview','POST',multipart(cfg.csv,{delimiter:'comma'}),200);
  const csvImport=await request('owner','/csv/import','POST',form({token:token(csv.text),case_column:'case',activity_column:'activity',timestamp_column:'time',lifecycle_column:'lifecycle',order:'source'}),303);
  state.logs.csv=csvImport.location.split('/').pop();const c=await exportLog('owner',state.logs.csv);counts(c,cfg.csv_sha);write('baseline-csv-export.json',c);
  for(const actor of ['editor','viewer','foreign']){
   const a=state.actors[actor];await request('owner','/users','POST',form({username:a.username,password:a.password}),303);
   if(actor!=='foreign')await request('owner','/projects/'+state.project+'/members','POST',form({username:a.username,role:actor}),303);
   await login(actor);if(actor!=='foreign'){await open(actor);assert.deepEqual(await exportLog(actor,state.logs.xes),x);}
  }
  write('http-private-state.json',JSON.stringify(state));
 }else if(mode==='negative'){
  const denied=await request('viewer','/csv/preview','POST',multipart(cfg.csv,{delimiter:'comma'}),403);assert.ok(denied.text.includes('access_denied'));
  const foreign=await request('foreign','/projects/'+state.project+'/open','POST',form({}),403);assert.ok(foreign.text.includes('access_denied'));
  const hidden=await request('foreign','/logs/'+state.logs.xes+'/export','GET',undefined,404);assert.ok(hidden.text.includes('not_found'));
  const cross=await request('owner','/projects','POST',form({name:'rejected-origin'}),403,'http://invalid.example');assert.ok(cross.text.includes('cross_origin'));
 }else if(mode==='restart'||mode==='recovery'){
  await login('owner');await open('owner');
  for(const kind of ['xes','csv'])assert.deepEqual(await exportLog('owner',state.logs[kind]),fs.readFileSync(path.join(root,'baseline-'+kind+'-export.json')));
  assert.deepEqual((await request('owner','/logs/'+state.logs.xes+'/original')).bytes,fs.readFileSync(path.join(root,'baseline-xes-original.xes')));
  assert.deepEqual((await request('owner','/logs/'+state.logs.xes+'/import-history')).bytes,fs.readFileSync(path.join(root,'baseline-xes-history.json')));
 }else throw Error('unknown_probe_mode');
 write(mode+'-http-result.json',JSON.stringify({status:'FINITE_HTTP_CHECKS_PASSED',mode,records,limits:['No browser/Datastar interaction proof','Same-host controlled failure; not infrastructure HA']},null,2));
}
main().catch(e=>{try{write(mode+'-http-failure.json',JSON.stringify({status:'FAILED_RETAINED',mode,reason:e.message,transport_code:e.code||null,cause_code:e.cause?.code||null,records},null,2));}catch{}process.exitCode=1;});
