'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),crypto=require('node:crypto');
function bounded(file,cap=16*1024*1024){assert.ok(fs.statSync(file).size<=cap);return fs.readFileSync(file,'utf8');}
function readState(file){
 const rows=bounded(file).trim().split(/\r?\n/),auth=[];
 const other=rows.filter(line=>{
  if(!line.startsWith('['))return true;
  const row=JSON.parse(line);
  if(row[0]==='pi_kv'&&row[1].key==='auth'){auth.push(row[1]);return false;}
  return true;
 });
 assert.equal(auth.length,1);assert.ok(Number.isSafeInteger(auth[0].version)&&auth[0].version>0);
 return {auth:auth[0],other};
}
function compare(pre,login,opened,loginHttp,openHttp,privateState){
 assert.deepEqual(pre.other,login.other);assert.deepEqual(pre.other,opened.other);
 assert.equal(login.auth.version,pre.auth.version+1);assert.equal(opened.auth.version,pre.auth.version+2);
 assert.equal(loginHttp.status,'FINITE_AUTH_HTTP_MUTATION_COMPLETED');assert.equal(openHttp.status,'FINITE_AUTH_HTTP_MUTATION_COMPLETED');
 assert.equal(loginHttp.mode,'login');assert.equal(openHttp.mode,'open');assert.equal(loginHttp.http_status,303);assert.equal(openHttp.http_status,303);
 assert.match(privateState.cookie,/^pi_session=[a-f0-9]{64}$/);
 const binding=crypto.createHash('sha256').update(privateState.cookie.slice('pi_session='.length)).digest('hex');
 const users=Object.entries(pre.auth.document.users).filter(([,u])=>u.username===privateState.username);
 assert.equal(users.length,1);const user=users[0][0];
 const projects=Object.entries(pre.auth.document.projects);
 assert.ok(projects.every(([id])=>/^project-[a-z0-9]+$/.test(id)));
 const eligible=projects.filter(([,p])=>!p.archived&&Object.hasOwn(p.members,user)).sort(([a],[b])=>a<b?-1:a>b?1:0);
 assert.ok(eligible.length>0);assert.ok(!Object.hasOwn(pre.auth.document.sessions,binding));
 const newSession=login.auth.document.sessions[binding];assert.ok(newSession);
 const now=newSession.expires-8*3600,start=Math.floor(Date.parse(loginHttp.started_utc)/1000),end=Math.floor(Date.parse(loginHttp.ended_utc)/1000);
 assert.ok(Number.isSafeInteger(now)&&Number.isFinite(start)&&Number.isFinite(end)&&end>=start&&end-start<=15&&now>=start&&now<=end);
 const expected=structuredClone(pre.auth.document);
 for(const[key,s]of Object.entries(expected.sessions)){if(s.expires<=now)delete expected.sessions[key];}
 expected.sessions[binding]={user_id:user,project_id:eligible[0][0],expires:now+8*3600};
 assert.deepEqual(login.auth.document,expected);
 assert.ok(expected.projects[privateState.project]&&!expected.projects[privateState.project].archived&&Object.hasOwn(expected.projects[privateState.project].members,user));
 expected.sessions[binding].project_id=privateState.project;
 assert.deepEqual(opened.auth.document,expected);
 const openStart=Date.parse(openHttp.started_utc),openEnd=Date.parse(openHttp.ended_utc);
 assert.ok(Number.isFinite(openStart)&&Number.isFinite(openEnd)&&openEnd>=openStart&&openEnd-openStart<=15000&&openStart>=Date.parse(loginHttp.ended_utc));
 return {status:'FINITE_COMPLETE_AUTH_DELTA_VERIFIED',auth_revision_delta:2,session_added:1,expired_removed:Object.values(pre.auth.document.sessions).filter(s=>s.expires<=now).length,all_other_auth_fields_exact:true,all_non_auth_rows_exact:true,limits:['Expected whole Auth derived from actual PRE and bounded server-time interval; credentials/cookie not emitted','Finite login/open only, not all session/lifecycle/CAS acceptance']};
}
if(require.main===module){
 try{
  assert.equal(process.argv.length,8);
  const [pre,login,opened]=process.argv.slice(2,5).map(readState);
  const [loginHttp,openHttp,privateState]=process.argv.slice(5,8).map(f=>JSON.parse(bounded(f,65536)));
  process.stdout.write(JSON.stringify(compare(pre,login,opened,loginHttp,openHttp,privateState))+'\n');
 }catch{process.stderr.write('auth_delta_contract_failed\n');process.exitCode=1;}
}
module.exports={compare};
