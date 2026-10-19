'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{isDeepStrictEqual}=require('node:util');
const {ownedHttp}=require('../owned-http-client.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),mode=process.argv[3],out=cfg.output_directory;
const put=(n,v)=>fs.writeFileSync(path.join(out,n),Buffer.isBuffer(v)?v:JSON.stringify(v,null,2),{flag:'wx'});
const read=p=>JSON.parse(fs.readFileSync(p,'utf8')),sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const rows=n=>fs.readFileSync(path.join(out,n),'utf8').trim().split('\n').map(JSON.parse);
function check(ok,code){if(!ok)throw Error(code);}
let records=[];
async function request(state,actor,route,method='GET',values,expected=200){
 const started=new Date().toISOString(),headers={Cookie:state.actors[actor].cookie};
 let body;if(method==='POST'){headers.Origin='http://127.0.0.1:3096';headers['Content-Type']='application/x-www-form-urlencoded';body=new URLSearchParams(values);}
 const r=await ownedHttp({port:3096,route,method,headers,body}),finished=new Date().toISOString(),body_file=`access-${mode}-${records.length+1}.body`;
 put(body_file,r.bytes);const record={actor,route,method,status:r.status,expected,started,finished,body_file,sha256:sha(r.bytes),bytes:r.bytes.length};records.push(record);
 check(r.status===expected,'audit_access_http_status');check(!r.headers['set-cookie'],'audit_access_cookie_change');return{...r,record};
}
function projection(trail,deletion=false){
 const t=trail||{total:0,entries:[]},value={scope:deletion?'former owner only; deletion witnesses, no deleted payloads':'current project owner; successful auth mutations; per-project last512',retention_capacity:512,total:t.total,dropped:t.total-t.entries.length,entries:t.entries};
 if(!deletion)value.visible_entries=t.entries.length;return value;
}
async function main(){
 if(/^[1-4]$/.test(mode)){
  const step=Number(mode),state=read(step===1?cfg.seed_state:path.join(out,`project-${step-1}.state.json`));
  const pre=rows(`project-${step}-pre.stdout`),auth=pre.find(r=>r[0]==='kv'&&r[1]==='auth')[3];
  if(step===1)state.target=auth.sessions[sha(state.actors.owner.cookie.split('=')[1])].project_id;
  const who=step===1||step===3?'editor':'viewer',actor=step<=2?'owner':who,kind=step<=2?'grant':'open';
  const values=step<=2?{username:state.actors[who].username,role:who}:{};
  const r=await request(state,actor,`/projects/${state.target}/${step<=2?'members':'open'}`,'POST',values,303);
  put(`project-${step}.intent.json`,{step,kind,actor,values,started:r.record.started,finished:r.record.finished,extra:{who}});
  put(`project-${step}.state.json`,state);put(`project-${step}.http-result.json`,{records});
 }else if(mode==='exports'){
  const state=read(path.join(out,'project-4.state.json')),pre=rows('exports-pre.stdout'),auth=pre.find(r=>r[0]==='kv'&&r[1]==='auth')[3];
  const summaries=[];let ownerTrail;
  for(const actor of ['owner','editor','viewer','foreign']){
   const s=auth.sessions[sha(state.actors[actor].cookie.split('=')[1])];check(s,'audit_access_bound_session');
   const role=auth.projects[s.project_id].members[s.user_id],trail=pre.find(r=>r[0]==='project'&&r[1]===s.project_id)?.[3].audit||{total:0,entries:[]};
   check(actor==='foreign'||role===actor,'audit_access_actual_current_role');
   const expected={schema_version:2,scope:'server business mutations committed; legacy policy/outcome unknown; client project-backup history explicitly unverified; retained last512 per scope',project_id:s.project_id,project_total:trail.total,project_dropped:trail.total-trail.entries.length,project_entries:trail.entries,
    auth_owner_projection:projection(role==='owner'?auth.audit?.[s.project_id]:null),deletion_owner_projection:projection(auth.deletions?.[s.user_id],true)};
   if(actor==='owner'){ownerTrail=expected.deletion_owner_projection;check(ownerTrail.total===513&&ownerTrail.entries.length===512,'positive_owner_witness_fixture');}
   else check(expected.deletion_owner_projection.total===0,'nonowner_fixture_has_own_witness');
   const r=await request(state,actor,'/audit/export');check(isDeepStrictEqual(JSON.parse(r.bytes.toString('utf8')),expected),'audit_access_full_pre_derived_export');
   put(actor+'-expected-export.json',expected);summaries.push({actor,current_role:role,project_id:s.project_id,deletion_total:expected.deletion_owner_projection.total,auth_visible:expected.auth_owner_projection.visible_entries});
  }
  const deleted=ownerTrail.entries.at(-1).project;check(!auth.projects[deleted],'witness_project_still_present');
  for(const actor of ['owner','editor','viewer','foreign']){
   const r=await request(state,actor,`/projects/${deleted}/delete`,'GET',undefined,403);check(r.bytes.toString('utf8').includes('access_denied'),'deleted_project_specific_refusal');
  }
  put('exports-http-result.json',{status:'FOUR_ROLE_FORMER_OWNER_WITNESS_EXPORTS_VERIFIED',summaries,records,limits:['Finite four actors/current roles on one actual 513-witness fixture; no universal access proof']});
 }else throw Error('audit_access_mode');
 process.stdout.write(JSON.stringify({status:'AUDIT_ACCESS_HTTP_MODE_COMPLETED',mode,requests:records.length})+'\n');
}
main().catch(e=>{put('failure-'+mode+'.json',{status:'FAILED_RETAINED',reason:e.message,records});process.exitCode=1;});
