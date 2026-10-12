'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto'),{compare}=require('../tools/auth-delta-compare.cjs');
const token='a'.repeat(64),binding=crypto.createHash('sha256').update(token).digest('hex'),now=1800000000;
const doc={users:{'user-1':{username:'s11-owner',password_hash:'private-fixture-value',administrator:true}},projects:{'project-a':{id:'project-a',archived:false,members:{'user-1':'owner'}},'project-b':{id:'project-b',archived:false,members:{'user-1':'owner'}}},sessions:{old:{user_id:'user-1',project_id:'project-a',expires:now+50},expired:{user_id:'user-1',project_id:'project-a',expires:now-1}},audit:{'project-a':{total:1,entries:[{action:'fixture-retained'}]}}};
const pre={auth:{version:7,document:doc},other:['BEGIN','retained-full-other-row','COMMIT']};
const login=structuredClone(pre);login.auth.version++;delete login.auth.document.sessions.expired;login.auth.document.sessions[binding]={user_id:'user-1',project_id:'project-a',expires:now+28800};
const opened=structuredClone(login);opened.auth.version++;opened.auth.document.sessions[binding].project_id='project-b';
const http=(mode,offset)=>({status:'FINITE_AUTH_HTTP_MUTATION_COMPLETED',mode,http_status:303,started_utc:new Date((now+offset)*1000).toISOString(),ended_utc:new Date((now+offset+1)*1000).toISOString()});
const args=[pre,login,opened,http('login',0),http('open',2),{username:'s11-owner',project:'project-b',cookie:'pi_session='+token}];
assert.equal(compare(...args).all_other_auth_fields_exact,true);
const mutations=[
 a=>{a[1].auth.document.audit['project-a'].total++;},
 a=>{delete a[1].auth.document.sessions.old;},
 a=>{a[1].auth.document.users['user-1'].administrator=false;},
 a=>{a[1].auth.document.sessions[binding].expires+=30;},
 a=>{a[2].auth.version++;},
 a=>{a[2].other[1]='changed-other-row';},
 a=>{a[2].auth.document.sessions[binding].project_id='project-a';}
];
for(const mutate of mutations){const candidate=structuredClone(args);mutate(candidate);assert.throws(()=>compare(...candidate));}
process.stdout.write(JSON.stringify({status:'FINITE_AUTH_DELTA_ORACLE_REGRESSION_PASSED',scenarios:8,limits:['Synthetic full-PRE mutation refusals only, not actual HTTP/PostgreSQL acceptance']})+'\n');
