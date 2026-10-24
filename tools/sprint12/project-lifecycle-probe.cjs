'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {ownedHttp}=require('../owned-http-client.cjs');
const {namedProjectOpenId}=require('./named-project-row.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),step=Number(process.argv[3]),out=cfg.output_directory;
const read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
const put=(name,value)=>fs.writeFileSync(path.join(out,name),JSON.stringify(value,null,2),{flag:'wx'});
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function check(ok,code){if(!ok)throw Error(code);}
const state=step===1?{actors:read(cfg.credentials)}:read(path.join(out,`project-${step-1}.state.json`));
const rows=fs.readFileSync(path.join(out,`project-${step}-pre.stdout`),'utf8').trim().split('\n').map(JSON.parse);
const auth=rows.find(r=>r[0]==='kv'&&r[1]==='auth')?.[3]||{users:{},projects:{},sessions:{}};
const records=[];
async function request(actor,route,method='GET',body,status=200){
 const headers={};if(state.actors[actor]?.cookie)headers.Cookie=state.actors[actor].cookie;
 if(method==='POST'){headers.Origin='http://127.0.0.1:3096';if(!(body instanceof FormData)){body=new URLSearchParams(body);headers['Content-Type']='application/x-www-form-urlencoded';}}
 const r=await ownedHttp({port:3096,route,method,body,headers}),label=`project-${step}-http-${records.length+1}`;
 fs.writeFileSync(path.join(out,label+'.body'),r.bytes,{flag:'wx'});
 if(r.headers['set-cookie']){check(r.headers['set-cookie'].length===1,'cookie_count');state.actors[actor].cookie=r.headers['set-cookie'][0].split(';')[0];}
 records.push({route,method,status:r.status,expected:status,body_file:label+'.body',sha256:sha(r.bytes),bytes:r.bytes.length,location:r.headers.location||null});
 check(r.status===status,'unexpected_http_status');return r;
}
const revision=id=>String(auth.projects[id]?.revision||1);
async function main(){
 let actor='owner',route,values={},status=303,error=null,kind,extra={};
 const id=state.target;
 switch(step){
 case 1:route='/setup';values={username:state.actors.owner.username,password:state.actors.owner.password};kind='setup';break;
 case 2:case 3:case 4:{const who=['editor','viewer','foreign'][step-2];route='/users';values={username:state.actors[who].username,password:state.actors[who].password};kind='user';extra.who=who;break;}
 case 5:route='/projects';values.name='S12 project';kind='create';break;
 case 6:route=`/projects/${id}/rename`;values={name:'S12 renamed',revision:revision(id)};kind='rename';break;
 case 7:case 8:{const who=step===7?'editor':'viewer';route=`/projects/${id}/members`;values={username:state.actors[who].username,role:who};kind='grant';extra.who=who;break;}
 case 9:route=`/projects/${id}/open`;kind='open';break;
 case 10:case 12:case 14:actor=step===10?'editor':step===12?'viewer':'foreign';route='/login';values={username:state.actors[actor].username,password:state.actors[actor].password};kind='login';break;
 case 11:case 13:actor=step===11?'editor':'viewer';route=`/projects/${id}/open`;kind='open';break;
 case 15:case 16:actor=step===15?'editor':'viewer';route=`/projects/${id}/rename`;values={name:'Forbidden rename',revision:revision(id)};status=403;error='access_denied';kind='refusal';break;
 case 17:actor='foreign';route=`/projects/${id}/open`;status=403;error='access_denied';kind='refusal';break;
 case 18:route=`/projects/${id}/rename`;values={name:'Stale rename',revision:String(Number(revision(id))-1)};status=409;error='project_conflict';kind='refusal';break;
 case 19:route='/folders';values={name:'Durable project folder',revision:'0'};kind='folder';break;
 case 20:case 23:route=`/projects/${id}/archive`;values.revision=revision(id);kind='archive';break;
 case 21:route=`/projects/${id}/unarchive`;values.revision=revision(id);kind='unarchive';break;
 case 22:route=`/projects/${id}/open`;kind='open';break;
 case 24:case 25:case 26:case 27:case 28:{
  const preview=await request('owner',`/projects/${id}/delete`);
  const html=preview.bytes.toString('utf8');
  const match=name=>{const m=html.match(new RegExp(`name="${name}" value="([^"]+)"`));check(m,'preview_field_missing');return m[1];};
  values={confirmation_id:id,phrase:'УДАЛИТЬ',revision:match('revision'),digest:match('digest')};
  extra.actual_preview={...values};
  if(step===24)values.confirmation_id='project-wrong';
  if(step===25)values.phrase='DELETE';
  if(step===26)values.revision=String(Number(values.revision)-1);
  if(step===27)values.digest='0'.repeat(64);
  state.deleteConfirmation={...values};route=`/projects/${id}/delete`;kind=step===28?'delete':'refusal';
  if(step!==28){status=422;error='project_delete_confirmation';}break;
 }
 case 29:route=`/projects/${id}/delete`;values=state.deleteConfirmation;kind='refusal';status=403;error='access_denied';break;
 case 30:route=`/projects/${id}/open`;kind='refusal';status=403;error='access_denied';break;
 case 31:{
  const payload={logs:{},current:{},sequence:0,user_views:{},models:{},durable_jobs:{}};
  extra.restore_payload=payload;extra.restore_name='S12 restored empty';
  const source_project_id=auth.sessions[sha(state.actors.owner.cookie.split('=')[1])].project_id;
  extra.restore_source_project_id=source_project_id;
  const bundle={schema_version:1,source_project_id,payload,digest_sha256:sha(canonical(payload))};
  values=new FormData();values.set('file',new Blob([JSON.stringify(bundle)]),'s12-backup.json');values.set('name',extra.restore_name);
  route='/restore';kind='restore';status=200;break;
 }
 case 32:route=`/projects/${state.restored}/open`;kind='open';extra.open_id=state.restored;break;
 default:throw Error('unknown_project_step');
 }
 const started=new Date().toISOString();const response=await request(actor,route,'POST',values,status);const finished=new Date().toISOString();
 if(error)check(response.bytes.toString('utf8').includes(error),'unexpected_refusal_reason');
 if(kind==='create'){
  const html=(await request('owner','/projects')).bytes.toString('utf8');
  state.target=namedProjectOpenId(html,'S12 project');
 }
 if(kind==='folder'){
  const folders=JSON.parse((await request('owner','/folders/json')).bytes.toString('utf8')).organization.folders;
  const ids=Object.keys(folders);check(ids.length===1,'created_folder_count');extra.folder_id=ids[0];
 }
 if(kind==='restore'){
  const m=response.bytes.toString('utf8').match(/action="\/projects\/(project-[a-f0-9]{32})\/open"/);check(m,'restore_project_id');state.restored=m[1];
 }
 const intent={step,actor,kind,route,status,error,started,finished,extra};
 if(!(values instanceof FormData)){intent.values={...values};delete intent.values.password;}
 put(`project-${step}.intent.json`,intent);put(`project-${step}.state.json`,state);put(`project-${step}.http-result.json`,{status:'FINITE_HTTP_PROJECT_STEP_COMPLETED',records});
 process.stdout.write(JSON.stringify({step,status:'HTTP_STEP_COMPLETED',kind})+'\n');
}
main().catch(error=>{try{put(`project-${step}.http-failure.json`,{status:'FAILED_RETAINED',reason:error.message,records});}catch{}process.exitCode=1;});
