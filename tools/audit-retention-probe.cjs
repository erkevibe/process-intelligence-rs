'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {ownedHttp}=require('./owned-http-client.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),mode=process.argv[3],root=cfg.output_directory;
assert.equal(cfg.app_port,3095);assert.ok(['prepare','at512','at513','negative','restart'].includes(mode));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex'),write=(name,value)=>fs.writeFileSync(path.join(root,name),typeof value==='string'||Buffer.isBuffer(value)?value:JSON.stringify(value,null,2),{flag:'wx'});
function read(file,cap=16*1024*1024){assert.ok(fs.statSync(file).size<=cap);return JSON.parse(fs.readFileSync(file,'utf8'));}
function authSnapshot(file){
 assert.ok(fs.statSync(file).size<=16*1024*1024);
 const rows=fs.readFileSync(file,'utf8').split(/\r?\n/).filter(s=>s.startsWith('[')).map(JSON.parse);
 const auth=rows.filter(r=>r[0]==='pi_kv'&&r[1].key==='auth');assert.equal(auth.length,1);return auth[0][1];
}
let counter=0,records=[];
async function request(cookie,route,method='GET',body,expected=200){
 const started=new Date().toISOString(),r=await ownedHttp({port:3095,route,method,body,headers:{Cookie:cookie,...(method==='POST'?{Origin:'http://127.0.0.1:3095'}:{})}}),ended=new Date().toISOString();
 const name=mode+'-'+String(++counter).padStart(3,'0'),record={route,method,http_status:r.status,started_utc:started,ended_utc:ended,response_bytes:r.bytes.length,response_sha256:sha(r.bytes)};
 write('audit-'+name+'.body',r.bytes);write('audit-'+name+'.json',record);records.push(record);
 assert.equal(r.status,expected);assert.equal(r.headers['set-cookie'],undefined);
 return {record,bytes:r.bytes,text:r.bytes.toString('utf8'),location:r.headers.location,json:()=>JSON.parse(r.bytes.toString('utf8'))};
}
async function audit(cookie){return await request(cookie,'/audit/export');}
function safeReport(bytes){assert.ok(!/"(?:password_hash|password|cookie|sessions)"\s*:/.test(bytes.toString('utf8')));}
async function main(){
 if(mode==='prepare'){
  const auth=authSnapshot(path.join(root,'audit-pre.stdout')),session=read(path.join(root,'auth-delta-private.json'),65536);
  assert.match(session.cookie,/^pi_session=[a-f0-9]{64}$/);
  const binding=sha(session.cookie.slice('pi_session='.length)),stored=auth.document.sessions[binding];assert.ok(stored&&stored.project_id===session.project);
  const project=auth.document.projects[session.project],trail=auth.document.audit?.[session.project]||{total:0,entries:[]};
  assert.equal(project.members[stored.user_id],'owner');assert.ok(Number.isSafeInteger(project.revision)&&Number.isSafeInteger(trail.total)&&trail.total<512);
  const baseline=await audit(session.cookie);safeReport(baseline.bytes);
  assert.equal(baseline.json().project_id,session.project);
  write('audit-baseline-export.json',baseline.bytes);
  write('audit-retention-private.json',{cookie:session.cookie,project:session.project,actor:stored.user_id,initial_revision:project.revision,initial_total:trail.total,needed:512-trail.total});
 }else{
  const state=read(path.join(root,'audit-retention-private.json'),65536);
  async function rename(i){
   const name='s11-retention-'+String(i).padStart(3,'0'),expectedRevision=state.initial_revision+i-1;
   const r=await request(state.cookie,'/projects/'+state.project+'/rename','POST',new URLSearchParams({name,revision:String(expectedRevision)}),303);
   assert.equal(r.location,'/projects');return {...r.record,name,expected_revision:expectedRevision};
  }
  if(mode==='at512'||mode==='at513'){
   const ops=[];if(mode==='at512'){for(let i=1;i<=state.needed;i++)ops.push(await rename(i));}else ops.push(await rename(state.needed+1));
   const report=await audit(state.cookie);safeReport(report.bytes);
   write('audit-'+mode+'-export.json',report.bytes);write('audit-'+mode+'-operations.json',ops);
  }else if(mode==='negative'){
   const seed=read(path.join(root,'http-private-state.json'));
   const current=state.initial_revision+state.needed+1,route='/projects/'+state.project+'/rename';
   const viewer=await request(seed.actors.viewer.cookie,route,'POST',new URLSearchParams({name:'rejected-viewer',revision:String(current)}),403);assert.ok(viewer.text.includes('access_denied'));
   const stale=await request(state.cookie,route,'POST',new URLSearchParams({name:'rejected-stale',revision:String(current-1)}),409);assert.ok(stale.text.includes('project_conflict'));
   const view=await audit(seed.actors.viewer.cookie);safeReport(view.bytes);assert.equal(view.json().project_id,state.project);assert.equal(view.json().auth_owner_projection.total,0);assert.deepEqual(view.json().auth_owner_projection.entries,[]);
   const foreign=await audit(seed.actors.foreign.cookie);safeReport(foreign.bytes);assert.notEqual(foreign.json().project_id,state.project);assert.ok(foreign.json().auth_owner_projection.entries.every(e=>e.project!==state.project));
  }else if(mode==='restart'){
   const report=await audit(state.cookie);safeReport(report.bytes);assert.deepEqual(report.bytes,fs.readFileSync(path.join(root,'audit-at513-export.json')));write('audit-restart-export.json',report.bytes);
  }
 }
 write('audit-'+mode+'-http-result.json',{status:'FINITE_AUDIT_HTTP_CASE_COMPLETED',mode,records,limits:['Named Auth-owner rename retention only; no browser/Datastar or whole R3 acceptance']});
 process.stdout.write(JSON.stringify({status:'FINITE_AUDIT_HTTP_CASE_COMPLETED',mode,requests:records.length})+'\n');
}
main().catch(e=>{try{write('audit-'+mode+'-http-failure.json',{status:'FAILED_RETAINED',mode,reason:e.message,records});}catch{}process.exitCode=1;});
