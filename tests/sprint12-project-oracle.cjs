'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const root=path.resolve(process.argv[2]);if(!root.includes(path.join('.local','sprint12','root'))||fs.readdirSync(root).length)throw Error('new_private_fixture_required');
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const user='user-00000000000040008000000000000001',project='project-00000000000040008000000000000002',password='S12FixturePassword123',token='a'.repeat(64),salt=Buffer.from('00112233445566778899aabbccddeeff','hex');
const hash=crypto.argon2Sync('argon2id',{message:password,nonce:salt,parallelism:1,tagLength:32,memory:19456,passes:2});
const password_hash='$argon2id$v=19$m=19456,t=2,p=1$'+salt.toString('base64').replace(/=+$/,'')+'$'+hash.toString('base64').replace(/=+$/,'');
const params={empty_workspace_required:true,initial_user_id:user,default_project_id:project,initial_account_admin:true,default_project_role:'owner'};
const entry={sequence:1,at:'2026-10-19T08:00:01Z',actor:user,project,action:'platform_initialized',resources:[user,project],revision:1,policy:{version:1,rule:'empty_workspace_initial_admin_v1',parameters_sha256:sha(canonical(params))},outcome:'committed'};
const auth={users:{[user]:{id:user,username:'fixture_owner',password_hash,admin:true}},projects:{[project]:{id:project,name:'Мой проект',members:{[user]:'owner'}}},sessions:{[sha(token)]:{user_id:user,project_id:project,expires:Date.parse('2026-10-19T08:00:01Z')/1000+28800}},audit:{[project]:{total:1,entries:[entry]}}};
const pre=[['sequence','1','0',false]],post=[['kv','auth','1',auth],...structuredClone(pre)];
const intent={step:1,actor:'owner',kind:'setup',started:'2026-10-19T08:00:00Z',finished:'2026-10-19T08:00:02Z',extra:{},values:{username:'fixture_owner'}};
const state={actors:{owner:{username:'fixture_owner',password,cookie:'pi_session='+token}}};
const cases=[
 ['valid-setup',true,()=>{}],
 ['forged-actor',false,x=>{x.post[0][3].audit[project].entries[0].actor='user-forged';}],
 ['forged-policy',false,x=>{x.post[0][3].audit[project].entries[0].policy.parameters_sha256='0'.repeat(64);}],
 ['wrong-password',false,x=>{x.state.actors.owner.password='DifferentPassword123';}],
 ['foreign-session',false,x=>{x.post[0][3].sessions[sha(token)].project_id='project-foreign';}],
 ['expiry-too-long',false,x=>{x.post[0][3].sessions[sha(token)].expires+=3600;}],
 ['hidden-auth-delta',false,x=>{x.post[0][3].hidden='unexpected';}],
 ['unrelated-sequence-delta',false,x=>{x.post[1][1]='2';}],
 ['refusal-unchanged',true,x=>{x.intent.kind='refusal';x.post=structuredClone(x.pre);}],
 ['refusal-with-success',false,x=>{x.intent.kind='refusal';}],
];
const results=[];
for(const[name,pass,mutate]of cases){
 const dir=path.join(root,name);fs.mkdirSync(dir);const x=structuredClone({pre,post,intent,state});mutate(x);
 for(const[tag,value]of [['pre',x.pre],['post',x.post]])fs.writeFileSync(path.join(dir,`project-1-${tag}.stdout`),value.map(JSON.stringify).join('\n')+'\n',{flag:'wx'});
 fs.writeFileSync(path.join(dir,'project-1.intent.json'),JSON.stringify(x.intent),{flag:'wx'});fs.writeFileSync(path.join(dir,'project-1.state.json'),JSON.stringify(x.state),{flag:'wx'});
 const child=spawnSync(process.execPath,[path.resolve('tools/sprint12/project-lifecycle-oracle.cjs'),dir,'1'],{timeout:3000,encoding:'utf8',maxBuffer:65536,windowsHide:true});
 fs.writeFileSync(path.join(dir,'oracle.stdout'),child.stdout||'',{flag:'wx'});fs.writeFileSync(path.join(dir,'oracle.stderr'),child.stderr||'',{flag:'wx'});
 const ok=!child.error&&child.signal===null&&(pass?child.status===0:child.status!==0);results.push({name,expected_pass:pass,native_exit:child.status,passed:ok});
 if(!ok){fs.writeFileSync(path.join(root,'failure.json'),JSON.stringify(results));throw Error('project_oracle_regression_failed_'+name);}
}
fs.writeFileSync(path.join(root,'result.json'),JSON.stringify({status:'PASS',cases:results},null,2),{flag:'wx'});process.stdout.write(JSON.stringify({status:'PASS',checks:results.length})+'\n');
