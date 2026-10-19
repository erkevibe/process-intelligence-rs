'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {ownedHttp}=require('../owned-http-client.cjs'),{namedProjectOpenId}=require('./named-project-row.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),mode=process.argv[3],out=cfg.output_directory;
const prior={repo512:null,repo513:'repo512',survivor512:'repo513',survivor513:'survivor512'};
if(!Object.hasOwn(prior,mode))throw Error('retention_mode_scope');
const read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
const state=read(prior[mode]?path.join(out,prior[mode]+'.state.json'):cfg.seed_state);
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const put=(name,value)=>fs.writeFileSync(path.join(out,name),Buffer.isBuffer(value)?value:canonical(value),{flag:'wx'});
function check(ok,code){if(!ok)throw Error(code);}
const equal=(a,b,code)=>check(canonical(a)===canonical(b),code);
const expected=fs.readFileSync(path.join(out,mode+'-pre.stdout'),'utf8').trim().split('\n').map(JSON.parse);
const authRow=expected.find(r=>r[0]==='kv'&&r[1]==='auth'),auth=authRow[3];
const cookie=state.actors.owner.cookie,binding=sha(cookie.split('=')[1]),session=auth.sessions[binding];check(session,'retention_session_missing');
const project=session.project_id,actor=session.user_id,row=expected.find(r=>r[0]==='project'&&r[1]===project);check(row&&auth.projects[project].members[actor]==='owner','retention_project_scope');
const header=row[3],records=[],operations=[];let counter=0;
async function request(route,method='GET',values,status=200){
 const headers={Cookie:cookie};let body;
 if(method==='POST'){headers.Origin='http://127.0.0.1:3096';body=new URLSearchParams(values);}
 const started=new Date().toISOString(),r=await ownedHttp({port:3096,route,method,body,headers}),finished=new Date().toISOString(),name=mode+'-http-'+String(++counter).padStart(5,'0');
 put(name+'.body',r.bytes);const record={route,method,status:r.status,expected:status,started,finished,bytes:r.bytes.length,sha256:sha(r.bytes),body_file:name+'.body'};records.push(record);put(name+'.json',record);
 check(r.status===status,'retention_http_status');check(!r.headers['set-cookie'],'retention_session_changed');return{...r,record};
}
function projection(trail,deletion=false){
 const t=trail||{total:0,entries:[]},value={scope:deletion?'former owner only; deletion witnesses, no deleted payloads':'current project owner; successful auth mutations; per-project last512',retention_capacity:512,total:t.total,dropped:t.total-t.entries.length,entries:t.entries};
 if(!deletion)value.visible_entries=t.entries.length;return value;
}
function report(){const trail=header.audit||{total:0,entries:[]};return{schema_version:2,scope:'server business mutations committed; legacy policy/outcome unknown; client project-backup history explicitly unverified; retained last512 per scope',project_id:project,project_total:trail.total,project_dropped:trail.total-trail.entries.length,project_entries:trail.entries,auth_owner_projection:projection(auth.audit?.[project]),deletion_owner_projection:projection(auth.deletions?.[actor],true)};}
function entry(operation,at,total,action,resources,revision,parameters,rule,target=project){
 const n=Date.parse(at);check(Number.isFinite(n)&&n>=Date.parse(operation.started)&&n<=Date.parse(operation.finished),'retention_entry_time');
 return{sequence:total,at,actor,project:target,action,resources,revision,policy:{version:1,rule,parameters_sha256:sha(canonical(parameters))},outcome:'committed'};
}
async function repo(){
 const initial=header.audit.total,wanted=mode==='repo512'?512:513,needed=wanted-initial;
 check(needed>0&&needed<=512&&(mode!=='repo513'||needed===1),'repo_retention_initial_total');
 for(let i=1;i<=needed;i++){
  const revision=Number(row[2]),creating=!state.retention_folder,name='S12 retention '+(initial+i);
  const route=creating?'/folders':`/folders/${state.retention_folder}/rename`;
  const response=await request(route,'POST',{revision:String(revision),name},303);
  const organization=structuredClone(header.organization||{folders:{},assignments:{}});
  if(creating){
   const observed=JSON.parse((await request('/folders/json')).bytes.toString('utf8'));
   const added=Object.keys(observed.organization.folders).filter(id=>!Object.hasOwn(organization.folders,id));check(added.length===1&&/^folder-[a-f0-9-]{36}$/.test(added[0]),'retention_folder_identity');state.retention_folder=added[0];organization.folders[added[0]]={name,parent:null};
  }else organization.folders[state.retention_folder].name=name;
  const action=creating?'folder_created':'folder_renamed',resources=[state.retention_folder];
  const parameters={action,expected_repository_revision:revision,resources,validated_action_parameters:null,logs:[],organization,jobs:{},models:[],actor_current:null,actor_views:null};
  operations.push({kind:'repository',action,resources,revision:revision+1,parameters,request:response.record,total:initial+i});
  header.organization=organization;row[2]=String(revision+1);
 }
 const exported=await request('/audit/export'),actual=JSON.parse(exported.bytes.toString('utf8'));
 let trail=structuredClone(header.audit);
 for(const operation of operations){
  const observed=actual.project_entries.find(e=>e.sequence===operation.total);check(observed,'repository_retention_entry_missing');
  const e=entry(operation.request,observed.at,operation.total,operation.action,operation.resources,operation.revision,operation.parameters,'project_catalog_folder_cas_v1');
  equal(observed,e,'repository_retention_policy');trail={total:operation.total,entries:[...trail.entries,e].slice(-512)};
 }
 header.audit=trail;equal(actual,report(),'repository_retention_full_export');put(mode+'-export.json',exported.bytes);
}
async function survivor(){
 const baseline=auth.deletions?.[actor]||{total:0,entries:[]},initial=baseline.total,wanted=mode==='survivor512'?512:513,needed=wanted-initial;
 check(needed>0&&needed<=512&&(mode!=='survivor513'||needed===1),'survivor_retention_initial_total');
 for(let i=1;i<=needed;i++){
  const name='S12 survivor '+(initial+i),beforeRevision=Number(authRow[2]);
  await request('/projects','POST',{name},303);
  const projects=await request('/projects'),id=namedProjectOpenId(projects.bytes.toString('utf8'),name);
  check(/^project-[a-f0-9]{12}4[a-f0-9]{3}[89ab][a-f0-9]{15}$/.test(id)&&!auth.projects[id],'survivor_new_identity');
  await request(`/projects/${id}/archive`,'POST',{revision:'1'},303);
  const p={project_id:id,name,revision:2,auth_revision:beforeRevision+2,repository_revision:0,logs:0,models:0,folders:0,members:1,active_jobs:0,digest:''};
  const target={id,name,members:{[actor]:'owner'},archived:true,revision:2};
  p.digest=sha(canonical({preview:p,project:target,actor_id:actor,session_binding:binding}));
  const preview=await request(`/projects/${id}/delete`),html=preview.bytes.toString('utf8');
  const field=name=>{const m=html.match(new RegExp(`name="${name}" value="([^"]+)"`));check(m,'survivor_preview_field');return m[1];};
  check(field('revision')==='2'&&field('digest')===p.digest,'survivor_independent_preview_digest');
  const response=await request(`/projects/${id}/delete`,'POST',{confirmation_id:id,phrase:'УДАЛИТЬ',revision:'2',digest:p.digest},303);
  const parameters={project_id:id,project_revision:2,auth_revision:beforeRevision+2,confirmed_id:id,confirmation_phrase:'УДАЛИТЬ',preview_digest:p.digest,repository_revision:0,logs:0,models:0,folders:0,members:1,archived_required:true,active_jobs:0,typed_identity_required:true,backup_verified_by_application:false};
  operations.push({kind:'deletion',target:id,total:initial+i,request:response.record,parameters});authRow[2]=String(beforeRevision+3);
 }
 const exported=await request('/audit/export'),actual=JSON.parse(exported.bytes.toString('utf8'));
 let trail=structuredClone(baseline);
 for(const operation of operations){
  const observed=actual.deletion_owner_projection.entries.find(e=>e.sequence===operation.total);check(observed,'survivor_retention_entry_missing');
  const e=entry(operation.request,observed.at,operation.total,'project_deleted',[operation.target],3,operation.parameters,'owner_archived_exact_confirmation_cas_v1',operation.target);
  equal(observed,e,'survivor_retention_policy');trail={total:operation.total,entries:[...trail.entries,e].slice(-512)};
 }
 auth.deletions??={};auth.deletions[actor]=trail;equal(actual,report(),'survivor_retention_full_export');put(mode+'-export.json',exported.bytes);
}
async function main(){
 if(mode.startsWith('repo'))await repo();else await survivor();
 put(mode+'.expected-full-state.json',expected);put(mode+'.operations.json',operations);put(mode+'.state.json',state);
 put(mode+'.http-result.json',{status:'FINITE_MIXED_RETENTION_READY_FOR_FULL_DATABASE_COMPARISON',mode,operations:operations.length,records,limits:['Boundary whole-state proof; transient create/archive witnesses are separately covered by project32 per-commit evidence','No SQL-seeded audit success, every retained new entry comes from real HTTP mutation','No physical erasure or universal retention policy claim']});
 process.stdout.write(JSON.stringify({status:'FINITE_MIXED_RETENTION_READY',mode,operations:operations.length,requests:records.length})+'\n');
}
main().catch(error=>{try{put(mode+'.failure.json',{status:'FAILED_RETAINED',reason:error.message,records,operations});}catch{}process.exitCode=1;});
