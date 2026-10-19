'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const root=path.resolve(process.argv[2]);if(!root.includes(path.join('.local','sprint12','root'))||fs.readdirSync(root).length)throw Error('new_private_fixture_required');
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const view={threshold:2,selected:null,selected_case:null,revision:1};
const parameters={action:'view_changed',expected_repository_revision:1,resources:[],validated_action_parameters:null,logs:[],organization:null,jobs:{},models:[],actor_current:'log-1',actor_views:{'log-1':view}};
const pre=[['kv','auth','1',{sessions:{[sha('token')]:{user_id:'user-a',project_id:'project-a'}},projects:{'project-a':{members:{'user-a':'owner'}}}}],['project','project-a','1',{current:{'user-a':'log-1'},sequence:1,user_views:{},durable_jobs:{},log_ids:['log-1'],model_ids:[]}],['sequence','1','32',true]];
const post=structuredClone(pre);post[1][2]='2';post[1][3].user_views={'user-a':{'log-1':view}};post[1][3].audit={total:1,entries:[{sequence:1,at:'2026-10-19T08:00:01Z',actor:'user-a',project:'project-a',action:'view_changed',resources:[],revision:2,policy:{version:1,rule:'actor_private_view_v1',parameters_sha256:sha(canonical(parameters))},outcome:'committed'}]};
const intent={step:1,kind:'view',started:'2026-10-19T08:00:00Z',finished:'2026-10-19T08:00:02Z'},state={csv_id:'log-1',actors:{owner:{cookie:'pi_session=token'}}};
const cases=[
 ['valid-view',true,()=>{}],
 ['forged-actor',false,x=>{x.post[1][3].audit.entries[0].actor='user-forged';}],
 ['forged-policy',false,x=>{x.post[1][3].audit.entries[0].policy.parameters_sha256='0'.repeat(64);}],
 ['wrong-time',false,x=>{x.post[1][3].audit.entries[0].at='2026-10-19T09:00:00Z';}],
 ['hidden-auth-delta',false,x=>{x.post[0][3].hidden='unexpected';}],
 ['hidden-header-delta',false,x=>{x.post[1][3].hidden='unexpected';}],
 ['unexpected-sequence-delta',false,x=>{x.post[2][1]='2';}],
 ['refusal-conserves-all',true,x=>{x.intent.kind='refusal';x.post=structuredClone(x.pre);}],
 ['refusal-with-success',false,x=>{x.intent.kind='refusal';}],
];
const results=[];
for(const[name,pass,mutate]of cases){
 const dir=path.join(root,name);fs.mkdirSync(dir);const x=structuredClone({pre,post,intent,state});mutate(x);
 for(const[tag,value]of [['pre',x.pre],['post',x.post]])fs.writeFileSync(path.join(dir,`resource-1-${tag}.stdout`),value.map(JSON.stringify).join('\n')+'\n',{flag:'wx'});
 fs.writeFileSync(path.join(dir,'resource-1.intent.json'),JSON.stringify(x.intent),{flag:'wx'});fs.writeFileSync(path.join(dir,'resource-1.state.json'),JSON.stringify(x.state),{flag:'wx'});fs.writeFileSync(path.join(dir,'resource-1.http-result.json'),'{"records":[]}',{flag:'wx'});fs.writeFileSync(path.join(dir,'config.json'),'{}',{flag:'wx'});
 const child=spawnSync(process.execPath,[path.resolve('tools/sprint12/resource-lifecycle-oracle.cjs'),dir,'1',path.join(dir,'config.json')],{timeout:3000,encoding:'utf8',maxBuffer:65536,windowsHide:true});
 fs.writeFileSync(path.join(dir,'oracle.stdout'),child.stdout||'',{flag:'wx'});fs.writeFileSync(path.join(dir,'oracle.stderr'),child.stderr||'',{flag:'wx'});
 const ok=!child.error&&child.signal===null&&(pass?child.status===0:child.status!==0);results.push({name,expected_pass:pass,native_exit:child.status,passed:ok});
 if(!ok){fs.writeFileSync(path.join(root,'failure.json'),JSON.stringify(results));throw Error('resource_oracle_regression_failed_'+name);}
}
fs.writeFileSync(path.join(root,'result.json'),JSON.stringify({status:'PASS',cases:results},null,2),{flag:'wx'});process.stdout.write(JSON.stringify({status:'PASS',checks:results.length})+'\n');
