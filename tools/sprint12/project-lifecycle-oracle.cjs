'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const [out,number]=process.argv.slice(2),step=Number(number);
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const read=name=>JSON.parse(fs.readFileSync(path.join(out,name),'utf8'));
const rows=name=>fs.readFileSync(path.join(out,name),'utf8').trim().split('\n').map(JSON.parse);
const put=(name,value)=>fs.writeFileSync(path.join(out,name),canonical(value),{flag:'wx'});
function check(ok,code){if(!ok)throw Error(code);}
const equal=(a,b,code)=>check(canonical(a)===canonical(b),code);
const validId=(id,prefix)=>check(new RegExp(`^${prefix}-[a-f0-9]{12}4[a-f0-9]{3}[89ab][a-f0-9]{15}$`).test(id),'generated_identity_invalid');
const key=r=>({kv:'1'+r[1],project:'2'+r[1],record:'3'+r[1]+'/'+r[2]+'/'+r[3],marker:'4'+r[1]?.project_id,ledger:'5'+r[1]?.version,sequence:'6',sequence_definition:'7'})[r[0]];
const sortRows=r=>r.sort((a,b)=>key(a)<key(b)?-1:key(a)>key(b)?1:0);
try{
 const pre=rows(`project-${step}-pre.stdout`),post=rows(`project-${step}-post.stdout`),intent=read(`project-${step}.intent.json`),state=read(`project-${step}.state.json`);
 let expected=structuredClone(pre);
 const authRow=expected.find(r=>r[0]==='kv'&&r[1]==='auth'),authRevision=Number(authRow?.[2]||0);
 const auth=authRow?.[3]||{users:{},projects:{},sessions:{}};
 const observed=post.find(r=>r[0]==='kv'&&r[1]==='auth')?.[3];
 const currentCookie=state.actors[intent.actor].cookie?.split('=')[1];
 let actorSession=auth.sessions[sha(currentCookie||'')],actorId=actorSession?.user_id,currentId=actorSession?.project_id;
 const target=state.target,values=intent.values||{},parameters=[];
 const projectRevision=id=>auth.projects[id]?.revision||1;
 const projectHeader=id=>expected.find(r=>r[0]==='project'&&r[1]===id);
 const newProject=(id,name,owner)=>{validId(id,'project');check(!auth.projects[id],'project_identity_reused');auth.projects[id]={id,name,members:{[owner]:'owner'}};};
 function addEntry(trail,actual,project,action,resources,revision,params,rule,entryActor=actorId){
  const at=actual?.entries?.at(-1)?.at;check(typeof at==='string','audit_missing');
  const stamp=Date.parse(at);check(Number.isFinite(stamp)&&stamp>=Date.parse(intent.started)&&stamp<=Date.parse(intent.finished),'audit_time_outside_request');
  const total=(trail?.total||0)+1,entry={sequence:total,at,actor:entryActor,project,action,resources,revision,policy:{version:1,rule,parameters_sha256:sha(canonical(params))},outcome:'committed'};
  equal(actual.entries.at(-1),entry,'audit_identity_policy_or_outcome_mismatch');
  parameters.push({action,parameters:params});return{total,entries:[...(trail?.entries||[]),entry].slice(-512)};
 }
 function append(project,action,resources,revision,params,rule){
  auth.audit??={};auth.audit[project]=addEntry(auth.audit[project],observed.audit?.[project],project,action,resources,revision,params,rule);
 }
 function user(who,administrator){
  const credentials=state.actors[who],created=Object.keys(observed.users).filter(id=>!Object.hasOwn(auth.users,id));
  check(created.length===1,'new_user_count');const id=created[0];validId(id,'user');
  const actual=observed.users[id],parts=actual.password_hash?.split('$');
  check(parts?.length===6&&parts[1]==='argon2id'&&parts[2]==='v=19'&&parts[3]==='m=19456,t=2,p=1','password_hash_policy');
  const salt=Buffer.from(parts[4],'base64'),digest=Buffer.from(parts[5],'base64');
  check(salt.length===16&&digest.length===32,'password_hash_shape');
  check(crypto.argon2Sync('argon2id',{message:credentials.password,nonce:salt,parallelism:1,tagLength:32,memory:19456,passes:2}).equals(digest),'independent_argon2_verification_failed');
  const expectedUser={id,username:credentials.username,password_hash:actual.password_hash,admin:administrator};equal(actual,expectedUser,'created_user_fields');auth.users[id]=expectedUser;
  const projects=Object.keys(observed.projects).filter(p=>!Object.hasOwn(auth.projects,p));check(projects.length===1,'default_project_count');newProject(projects[0],'Мой проект',id);
  return{id,project:projects[0]};
 }
 function session(userId){
  check(/^[a-f0-9]{64}$/.test(currentCookie),'session_token_shape');
  const token=sha(currentCookie),actual=observed.sessions[token];check(actual,'new_session_missing');
  const started=Math.floor(Date.parse(intent.started)/1000),finished=Math.floor(Date.parse(intent.finished)/1000);
  check(Number.isInteger(actual.expires)&&actual.expires>=started+28800&&actual.expires<=finished+28800,'session_expiry_bound');
  for(const[key,value]of Object.entries(auth.sessions))if(value.expires<=started)delete auth.sessions[key];
  check(!Object.hasOwn(auth.sessions,token),'session_identity_reused');
  const project=Object.keys(auth.projects).sort().find(id=>!auth.projects[id].archived&&Object.hasOwn(auth.projects[id].members,userId));
  auth.sessions[token]={user_id:userId,project_id:project,expires:actual.expires};
 }
 const defaultHeader=()=>({current:{},sequence:0,user_views:{},durable_jobs:{},log_ids:[],model_ids:[]});
 function preview(){
  const project=auth.projects[target],row=projectHeader(target),header=row?.[3];
  const p={project_id:target,name:project.name,revision:projectRevision(target),auth_revision:authRevision,repository_revision:Number(row?.[2]||0),logs:header?.log_ids.length||0,models:header?.model_ids.length||0,folders:Object.keys(header?.organization?.folders||{}).length,members:Object.keys(project.members).length,active_jobs:Object.values(header?.durable_jobs||{}).filter(j=>!['completed','failed','cancelled'].includes(j.state)).length,digest:''};
  p.digest=sha(canonical({preview:p,project,actor_id:actorId,session_binding:sha(currentCookie)}));
  equal(intent.extra.actual_preview,{confirmation_id:target,phrase:'УДАЛИТЬ',revision:String(p.revision),digest:p.digest},'server_delete_preview_binding');return p;
 }
 let authChanged=intent.kind!=='refusal'&&intent.kind!=='folder';
 if(intent.kind==='refusal'){
  if(intent.extra.actual_preview)preview();
  equal(pre,post,'refusal_changed_full_database');
 }else if(intent.kind==='setup'){
  check(authRevision===0&&Object.keys(auth.users).length===0,'setup_not_empty');const created=user('owner',true);actorId=created.id;
  append(created.project,'platform_initialized',[created.id,created.project],1,{empty_workspace_required:true,initial_user_id:created.id,default_project_id:created.project,initial_account_admin:true,default_project_role:'owner'},'empty_workspace_initial_admin_v1');session(created.id);
 }else if(intent.kind==='user'){
  const created=user(intent.extra.who,false);
  append(currentId,'user_created',[created.id],projectRevision(currentId),{new_user_id:created.id,administrator_required:true,new_account_admin:false,owned_default_project_ids:[created.project],default_project_role:'owner'},'administrator_account_creation_v1');
 }else if(intent.kind==='create'){
  newProject(target,values.name,actorId);append(target,'project_created',[target],1,{name_sha256:sha(values.name),name_bytes:Buffer.byteLength(values.name),owner_id:actorId},'current_writer_new_owner_project_v1');
 }else if(intent.kind==='rename'){
  const revision=projectRevision(target);auth.projects[target].name=values.name;auth.projects[target].revision=revision+1;
  append(target,'project_renamed',[target],revision+1,{name_sha256:sha(values.name),name_bytes:Buffer.byteLength(values.name),expected_revision:revision},'owner_project_name_cas_v1');
 }else if(intent.kind==='grant'){
  const user=Object.values(auth.users).find(u=>u.username===values.username);check(user,'grantee_missing');const revision=projectRevision(target)+1;auth.projects[target].members[user.id]=values.role;auth.projects[target].revision=revision;
  append(target,'membership_changed',[target],revision,{user_id:user.id,role:values.role,target_owner_required:true,grant_owner_forbidden:true},'owner_nonowner_membership_v1');
 }else if(intent.kind==='login'){
  const user=Object.values(auth.users).find(u=>u.username===state.actors[intent.actor].username);check(user,'login_user_missing');session(user.id);
 }else if(intent.kind==='open'){
  const opened=intent.extra.open_id||target;check(auth.projects[opened]&&!auth.projects[opened].archived&&Object.hasOwn(auth.projects[opened].members,actorId),'open_not_authorized');auth.sessions[sha(currentCookie)].project_id=opened;
 }else if(intent.kind==='archive'||intent.kind==='unarchive'){
  const archived=intent.kind==='archive',revision=projectRevision(target);
  if(archived){
   const ids=Object.keys(auth.projects).sort();
   const replacement=ids.find(id=>id!==target&&!auth.projects[id].archived&&['owner','editor'].includes(auth.projects[id].members[actorId]));
   for(const s of Object.values(auth.sessions).filter(s=>s.project_id===target)){
    if(s.user_id===actorId){if(replacement)s.project_id=replacement;}
    else{const other=ids.find(id=>id!==target&&!auth.projects[id].archived&&Object.hasOwn(auth.projects[id].members,s.user_id));if(other)s.project_id=other;}
   }
  }
  auth.projects[target].revision=revision+1;if(archived)auth.projects[target].archived=true;else delete auth.projects[target].archived;
  append(target,archived?'project_archived':'project_restored',[target],revision+1,{archived,expected_revision:revision,session_policy:'initiator_current_requires_writable_replacement_others_accessible'},'owner_archive_session_cas_v1');
 }else if(intent.kind==='folder'){
  authChanged=false;check(!projectHeader(target),'folder_fixture_expected_empty_project');
  const header=defaultHeader(),id=intent.extra.folder_id;check(/^folder-[a-f0-9-]{36}$/.test(id),'folder_identity_invalid');
  header.organization={folders:{[id]:{name:'Durable project folder',parent:null}},assignments:{}};
  const actual=post.find(r=>r[0]==='project'&&r[1]===target)?.[3];
  const params={action:'folder_created',expected_repository_revision:0,resources:[id],validated_action_parameters:null,logs:[],organization:header.organization,jobs:{},models:[],actor_current:null,actor_views:null};
  header.audit=addEntry(null,actual?.audit,target,'folder_created',[id],1,params,'project_catalog_folder_cas_v1');expected.push(['project',target,'1',header]);
 }else if(intent.kind==='delete'){
  const p=preview(),params={project_id:target,project_revision:p.revision,auth_revision:authRevision,confirmed_id:target,confirmation_phrase:'УДАЛИТЬ',preview_digest:p.digest,repository_revision:p.repository_revision,logs:p.logs,models:p.models,folders:p.folders,members:p.members,archived_required:true,active_jobs:0,typed_identity_required:true,backup_verified_by_application:false};
  const owners=Object.entries(auth.projects[target].members).filter(([,role])=>role==='owner').map(([id])=>id);
  auth.deletions??={};for(const owner of owners)auth.deletions[owner]=addEntry(auth.deletions[owner],observed.deletions?.[owner],target,'project_deleted',[target],p.revision+1,params,'owner_archived_exact_confirmation_cas_v1');
  delete auth.projects[target];delete auth.audit[target];if(!Object.keys(auth.audit).length)delete auth.audit;
  for(const[key,s]of Object.entries(auth.sessions))if(s.project_id===target){const replacement=Object.keys(auth.projects).sort().find(id=>!auth.projects[id].archived&&Object.hasOwn(auth.projects[id].members,s.user_id));if(replacement)s.project_id=replacement;else delete auth.sessions[key];}
  expected=expected.filter(r=>!((r[0]==='project'||r[0]==='record')&&r[1]===target)&&!(r[0]==='marker'&&r[1].project_id===target)&&!(r[0]==='kv'&&r[1]==='repository/'+target));
 }else if(intent.kind==='restore'){
  const id=state.restored,name=intent.extra.restore_name;newProject(id,name,actorId);
  append(id,'project_backup_restored',[id],1,{new_project_id:id,name_sha256:sha(name),repository_sha256:sha(canonical(intent.extra.restore_payload)),audit_import_policy:'project_backup_unverified_v1',imported_audit_total:0,imported_audit_retained:0},'writer_validated_new_project_restore_v1');expected.push(['project',id,'1',defaultHeader()]);
 }else throw Error('unknown_project_oracle_kind');
 if(intent.kind!=='refusal'){
  if(authChanged){const row=expected.find(r=>r[0]==='kv'&&r[1]==='auth');if(row){row[2]=String(authRevision+1);row[3]=auth;}else expected.push(['kv','auth','1',auth]);}
  equal(sortRows(expected),sortRows(post),'unexpected_full_database_delta');
 }
 put(`project-${step}.expected-parameters.json`,parameters);put(`project-${step}.expected-full-state.json`,expected);
 process.stdout.write(JSON.stringify({status:'PROJECT_FULL_PRE_DERIVED_STATE_VERIFIED',step,kind:intent.kind,policy_count:parameters.length,all_rows_compared:true})+'\n');
}catch(error){process.stderr.write(error.message+'\n');process.exitCode=1;}
