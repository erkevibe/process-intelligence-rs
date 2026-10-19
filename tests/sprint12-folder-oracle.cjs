'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const root=path.resolve(process.argv[2]);
if(!root.includes(path.join('.local','sprint12','root'))||fs.readdirSync(root).length)throw Error('new_fixture_directory_required');
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a.localeCompare(b,'en'))):x);
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const id='folder-00000000-0000-4000-8000-000000000001',organization={folders:{[id]:{name:'S12 A',parent:null}},assignments:{}};
const parameters={action:'folder_created',expected_repository_revision:1,resources:[id],validated_action_parameters:null,logs:[],organization,jobs:{},models:[],actor_current:null,actor_views:null};
const entry={sequence:1,at:'2026-10-19T08:00:01Z',actor:'user-a',project:'project-a',action:'folder_created',resources:[id],revision:2,policy:{version:1,rule:'project_catalog_folder_cas_v1',parameters_sha256:sha(canonical(parameters))},outcome:'committed'};
const pre=[['kv','auth','1',{sessions:{[sha('token')]:{user_id:'user-a',project_id:'project-a'}},projects:{'project-a':{members:{'user-a':'owner'}}}}],['project','project-a','1',{current:{},sequence:0,user_views:{},durable_jobs:{},log_ids:['log-a'],model_ids:[]}],['sequence','1','0',true]];
const post=structuredClone(pre);post[1][2]='2';post[1][3].organization=organization;post[1][3].audit={total:1,entries:[entry]};
const before={revision:1,organization:{folders:{},assignments:{}},resources:['log-a']},after={revision:2,organization,resources:['log-a']};
const http={status:303,actor:'owner',action:'folder_created',resource:id,edit:{kind:'create',id,name:'S12 A',parent:null},started:'2026-10-19T08:00:00Z',finished:'2026-10-19T08:00:02Z'};
const cases=[
 ['valid',true,()=>{}],
 ['unexpected-auth-change',false,x=>{x.post[0][3].unexpected='hidden';}],
 ['forged-policy',false,x=>{x.post[1][3].audit.entries[0].policy.parameters_sha256='0'.repeat(64);}],
 ['wrong-time',false,x=>{x.post[1][3].audit.entries[0].at='2026-10-19T09:00:00Z';}],
 ['nonwriter',false,x=>{x.pre[0][3].projects['project-a'].members['user-a']='viewer';}],
 ['forged-api-pre-org',false,x=>{x.before.organization.folders[id]={name:'Injected',parent:null};}],
 ['forged-api-catalog',false,x=>{x.before.resources.push('foreign-log');}],
 ['refusal-conserves-all',true,x=>{x.http.status=400;x.post=structuredClone(x.pre);x.after=structuredClone(x.before);}],
 ['refusal-with-audit-write',false,x=>{x.http.status=400;x.after=structuredClone(x.before);}],
];
const results=[];
for(const[name,pass,mutate]of cases){
 const dir=path.join(root,name);fs.mkdirSync(dir);
 const x=structuredClone({pre,post,before,after,http});mutate(x);
 const put=(name,value)=>fs.writeFileSync(path.join(dir,name),JSON.stringify(value),{flag:'wx'});
 for(const[key,value]of [['pre',x.pre],['post',x.post]])fs.writeFileSync(path.join(dir,`step-1-${key}.stdout`),value.map(v=>JSON.stringify(v)).join('\n')+'\n',{flag:'wx'});
 put('step-1.pre-folders.json',x.before);put('step-1.post-folders.json',x.after);put('step-1.http-result.json',x.http);
 put('step-1.state.json',{project:'project-a',actors:{owner:{cookie:'pi_session=token'}}});
 const child=spawnSync(process.execPath,[path.resolve('tools/sprint12/folder-lifecycle-oracle.cjs'),dir,'1'],{timeout:2000,encoding:'utf8',maxBuffer:65536,windowsHide:true});
 fs.writeFileSync(path.join(dir,'oracle.stdout'),child.stdout||'',{flag:'wx'});fs.writeFileSync(path.join(dir,'oracle.stderr'),child.stderr||'',{flag:'wx'});
 const ok=!child.error&&child.signal===null&&(pass?child.status===0:child.status!==0);
 results.push({name,expected_pass:pass,native_exit:child.status,passed:ok});
 if(!ok){fs.writeFileSync(path.join(root,'failed.json'),JSON.stringify(results));throw Error('oracle_regression_failed_'+name);}
}
fs.writeFileSync(path.join(root,'result.json'),JSON.stringify({status:'PASS',cases:results},null,2),{flag:'wx'});
process.stdout.write(JSON.stringify({status:'PASS',checks:results.length})+'\n');
