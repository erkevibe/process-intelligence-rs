'use strict';
// SOURCE-ONLY. Full restored C2 compatibility; no browser or full-R3 acceptance.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),http=require('node:http'),readline=require('node:readline'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../.local/sprint13'),utf=new TextDecoder('utf8',{fatal:true}),sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function within(p){p=path.resolve(p);const r=path.relative(root,p);assert(r&&!r.startsWith('..')&&!path.isAbsolute(r));let q=p;while(q!==root){assert(!fs.lstatSync(q).isSymbolicLink());q=path.dirname(q);}return p;}
function read(p,cap=1048576){p=within(p);const s=fs.statSync(p);assert(s.isFile()&&s.size<=cap);return fs.readFileSync(p);}
function pin(p,cap){const b=read(p.path,cap);assert.equal(sha(b),p.sha256.toLowerCase());return b;}
let retained=0;function save(p,v){const b=Buffer.isBuffer(v)?v:Buffer.from(JSON.stringify(v,null,2));retained+=b.length;assert(retained<=1073741824);fs.writeFileSync(p,b,{flag:'wx'});}
function safe(v){if(typeof v==='number')assert(Number.isSafeInteger(v)||!Number.isInteger(v),'unsafe_integer');else if(v&&typeof v==='object')for(const x of Object.values(v))safe(x);return v;}
const equal=(a,b)=>assert.deepEqual(a,b);
async function snapshot(proof){
 const file=within(proof.path);assert(fs.statSync(file).size<=1073741824);const hash=crypto.createHash('sha256');let bytes=0;
 const input=fs.createReadStream(file);input.on('data',b=>{hash.update(b);bytes+=b.length;});const lines=readline.createInterface({input,crlfDelay:Infinity});
 const rows=new Map(),logs=new Map(),models=new Map(),headers=new Map();let auth=null,authVersion=null,legacyRepositoryRows=0;
 for await(const line of lines){assert(Buffer.byteLength(line)<=268435456);const v=safe(JSON.parse(line));assert(Array.isArray(v));
  const key=JSON.stringify(v[0]==='record'?v.slice(0,4):v[0]==='kv'||v[0]==='project'?v.slice(0,2):v[0]==='marker'?['marker',v[1].project_id]:v[0]==='ledger'?['ledger',v[1].version]:[v[0]]);assert(!rows.has(key));rows.set(key,sha(Buffer.from(line)));
  if(v[0]==='kv'&&v[1]==='auth'){auth=v[3];authVersion=BigInt(v[2]);}
  if(v[0]==='kv'&&v[1].startsWith('repository/'))legacyRepositoryRows++;
  if(v[0]==='project')headers.set(v[1],v[3]);
  if(v[0]==='record'&&['log_state','log_analysis'].includes(v[2])){const k=v[1]+'/'+v[3],x=logs.get(k)||{project:v[1],id:v[3]};x[v[2]]=v[5];logs.set(k,x);}
  if(v[0]==='record'&&v[2]==='model')models.set(v[1]+'/'+v[3],{project:v[1],id:v[3],document:v[5]});
 }
 assert.equal(bytes,proof.bytes);assert.equal(hash.digest('hex'),proof.sha256.toLowerCase());assert(auth&&authVersion>0n);
 for(const l of logs.values())assert(l.log_state&&l.log_analysis);return {rows,logs,models,headers,auth,authVersion,legacyRepositoryRows};
}
async function main(){
 assert.equal(process.argv.length,3);const cfgBytes=read(process.argv[2]);assert.equal(sha(cfgBytes),process.env.PI_FULL_RECOVERY_CONFIG_SHA);const c=JSON.parse(utf.decode(cfgBytes));
 assert.equal(c.scope,'s13-full-recovery-http');assert(['http','delta'].includes(c.mode));assert.equal(c.app_port,3097);assert.equal(c.pg_port,5465);assert.equal(c.version,'0.7.3');assert(/^pi_restore_s13_[a-z0-9_]{1,35}$/.test(c.database));
 const out=within(c.output_directory),end=Math.min(Date.now()+600000,Date.parse(c.deadline_utc));assert(end>Date.now()&&end<=Date.parse('2026-10-19T19:44:42Z'));
 const before=await snapshot(c.before);assert.equal(before.logs.size,20);assert.equal(before.rows.size,130);assert.equal(before.legacyRepositoryRows,10);
 if(c.mode==='delta'){
  const after=await snapshot(c.after),w=JSON.parse(utf.decode(pin(c.http_witness,4*1048576)));assert.equal(after.rows.size,130);assert.equal(after.legacyRepositoryRows,10);assert.equal(w.status,'FULL_RECOVERY_HTTP_CAPTURED_PENDING_DELTA');assert.equal(w.before_sha256,c.before.sha256.toLowerCase());
  const expected=structuredClone(before.auth);let mutations=0;assert.equal(w.logins.length,4);assert.equal(new Set(w.logins.map(x=>x.session_key)).size,4);equal(w.logins.map(x=>x.role).sort(),['editor','foreign','owner','viewer']);
  const deltaCreds=JSON.parse(utf.decode(pin(c.credentials_private,65536)));
  for(const login of w.logins){assert.equal(Object.values(before.auth.users).filter(u=>u.username===deltaCreds[login.role].username&&u.id===login.actor_id).length,1);assert.equal(w.operations.filter(e=>e.kind==='login'&&e.actor_id===login.actor_id&&e.session_key===login.session_key).length,1);}
  for(const event of w.operations){
   if(event.kind==='login'){
    const session=after.auth.sessions[event.session_key];assert(session);assert.equal(session.user_id,event.actor_id);assert(Number.isSafeInteger(session.expires));const now=session.expires-28800;
    assert(now>=event.before_seconds&&now<=event.after_seconds);for(const [k,s] of Object.entries(expected.sessions))if(s.expires<=now)delete expected.sessions[k];assert(Object.keys(expected.sessions).length<256);
    const first=Object.entries(expected.projects).sort(([a],[b])=>a<b?-1:a>b?1:0).find(([,p])=>!p.archived&&Object.hasOwn(p.members,event.actor_id));assert(first);expected.sessions[event.session_key]={user_id:event.actor_id,project_id:first[0],expires:session.expires};mutations++;
   }else{assert.equal(event.kind,'switch');assert(expected.sessions[event.session_key]);assert.equal(expected.sessions[event.session_key].user_id,event.actor_id);assert(Object.hasOwn(expected.projects[event.project].members,event.actor_id)&&!expected.projects[event.project].archived);expected.sessions[event.session_key].project_id=event.project;mutations++;}
  }
  equal(after.auth,expected);assert.equal(after.authVersion,before.authVersion+BigInt(mutations));
  const authKey=JSON.stringify(['kv','auth']);before.rows.delete(authKey);after.rows.delete(authKey);equal(after.rows,before.rows);
  const result={status:'EXACT_AUTH_SESSION_VERSION_AND_ALL_OTHER_ROWS_DELTA_PENDING_QA_TD',mutations,successful_logins:4,all_other_full_rows_identical:true,audit_policy_users_projects_unchanged:true,limits:['No mutation RBAC or browser claim','Expiry replay uses actual bounded session expires and source8h TTL','BPMN exact serializer oracle remains separately required']};save(path.join(out,'full-http-delta.json'),result);console.log(JSON.stringify(result));return;
 }
 const admission=JSON.parse(utf.decode(pin(c.runtime_admission)));assert.equal(admission.scope,'S13_FULL_C2_NEW_RESTORED_RUNTIME');assert.equal(admission.database,c.database);assert.equal(admission.version,c.version);assert.equal(admission.app_sha256,c.app_sha256);assert(admission.app_pid>0);
 const credentialProof=JSON.parse(utf.decode(pin(c.credential_native_record)));assert.equal(credentialProof.native_exit,0);assert(credentialProof.stdout_complete&&credentialProof.stderr_complete&&!credentialProof.capture_fault&&!credentialProof.output_limit&&!credentialProof.drain_timeout);
 const credentialResult=JSON.parse(utf.decode(pin(c.credential_result)));assert.equal(credentialResult.status,'FOUR_HISTORICAL_SYNTHETIC_CREDENTIALS_VERIFIED');assert.equal(credentialResult.checks.length,4);assert(credentialResult.checks.every(x=>x.matched===true));
 const creds=JSON.parse(utf.decode(pin(c.credentials_private,65536))),roles=['owner','editor','viewer','foreign'];equal(Object.keys(creds).sort(),[...roles].sort());
 const cookies={},actors={},sessions={},operations=[],logins=[],results=[];let serial=0;
 for(const r of roles){const u=Object.values(before.auth.users).filter(u=>u.username===creds[r].username);assert.equal(u.length,1);actors[r]=u[0].id;assert(credentialResult.checks.some(x=>x.role===r&&x.username===u[0].username&&x.matched));}
 async function req(role,route,method='GET',form,expected=200){
  assert(Date.now()<end&&++serial<=512);assert(route==='/health'||route==='/login'||/^\/projects\/project-[a-f0-9]{32}\/open$/.test(route)||/^\/(logs|models)\/[A-Za-z0-9_-]+\/(export|json)$/.test(route));
  const body=form?Buffer.from(new URLSearchParams(form).toString()):null;assert(!body||body.length<=4096);const headers={Connection:'close'};if(cookies[role])headers.Cookie=cookies[role];if(method==='POST'){headers.Origin='http://127.0.0.1:3097';headers['Content-Length']=body?.length||0;headers['Content-Type']='application/x-www-form-urlencoded';}
  const start=Date.now(),response=await new Promise((resolve,reject)=>{let n=0,settled=false;const chunks=[];const finish=(e,v)=>{if(settled)return;settled=true;clearTimeout(timer);e?reject(e):resolve(v);};
   const q=http.request({hostname:'127.0.0.1',port:3097,path:route,method,headers,agent:false},r=>{r.on('data',b=>{n+=b.length;if(n>268435456){r.destroy();q.destroy();finish(Error('response_cap'));}else chunks.push(b);});r.on('error',e=>finish(e));r.on('aborted',()=>finish(Error('aborted')));r.on('end',()=>r.complete?finish(null,{status:r.statusCode,headers:r.headers,bytes:Buffer.concat(chunks)}):finish(Error('incomplete')));});
   const timer=setTimeout(()=>{q.destroy();finish(Error('timeout'));},Math.max(1,Math.min(30000,end-Date.now())));q.on('error',e=>finish(e));q.end(body);
  });
  const stop=Date.now(),label='recovery-http-'+String(serial).padStart(4,'0');save(path.join(out,label+'.body'),response.bytes);save(path.join(out,label+'.json'),{actor:role,route,method,status:response.status,expected,bytes:response.bytes.length,sha256:sha(response.bytes),before:new Date(start).toISOString(),after:new Date(stop).toISOString()});assert.equal(response.status,expected);
  const set=response.headers['set-cookie'];if(set){assert.equal(route,'/login');assert.equal(set.length,1);const m=/^pi_session=([a-f0-9]+);/.exec(set[0]);assert(m);cookies[role]='pi_session='+m[1];sessions[role]=sha(Buffer.from(m[1]));}
  if(route==='/login'){assert.equal(response.headers.location,'/projects');const e={kind:'login',actor_id:actors[role],session_key:sessions[role],before_seconds:Math.floor(start/1000),after_seconds:Math.floor(stop/1000)};operations.push(e);logins.push({role,actor_id:actors[role],session_key:sessions[role]});}
  else if(method==='POST'&&expected===303){assert.equal(response.headers.location,'/logs');operations.push({kind:'switch',actor_id:actors[role],session_key:sessions[role],project:route.split('/')[2]});}
  return response;
 }
 const health=JSON.parse(utf.decode((await req(null,'/health')).bytes));assert.equal(health.version,'0.7.3');for(const role of roles){await req(role,'/login','POST',creds[role],303);assert(cookies[role]);}
 const projects=[...new Set([...before.logs.values(),...before.models.values()].map(x=>x.project))].sort();
 for(const project of projects){assert(before.auth.projects[project]);for(const role of roles){const allowed=!before.auth.projects[project].archived&&Object.hasOwn(before.auth.projects[project].members,actors[role]);await req(role,`/projects/${project}/open`,'POST',{},allowed?303:403);results.push({kind:'open_rbac',role,project,allowed});}}
 let logs=0,models=0;
 for(const project of projects){const who=roles.find(r=>Object.hasOwn(before.auth.projects[project].members,actors[r]));assert(who);await req(who,`/projects/${project}/open`,'POST',{},303);
  for(const l of before.logs.values()){if(l.project!==project)continue;const r=await req(who,`/logs/${l.id}/export`),e=safe(JSON.parse(utf.decode(r.bytes))),base=l.log_state,userView=before.headers.get(project)?.user_views?.[actors[who]]?.[l.id],s=userView?{...base,threshold:userView.threshold,selected:userView.selected,selected_case:userView.selected_case,view_revision:userView.revision}:base;
   equal(e.analysis,l.log_analysis);assert.equal(e.schema_version,1);assert.equal(e.log_id,l.id);assert.equal(e.project_id,project);assert.equal(e.name,s.filename);for(const k of ['analysis_version','view_revision','source_sha256','elapsed_ms'])assert.equal(e[k],s[k]);
   equal(e.parameters,{min_edge_frequency:s.threshold,order:s.order,lifecycle:'each-event',filters:s.filters,calendar:s.calendar});assert.equal(Object.hasOwn(e,'created_at'),Object.hasOwn(s,'created_at'));if(Object.hasOwn(s,'created_at'))equal(e.created_at,s.created_at);logs++;results.push({kind:'full_log_analysis_stored_metadata_equal',project,id:l.id,bytes:r.bytes.length,sha256:sha(r.bytes)});
  }
  for(const m of before.models.values()){if(m.project!==project)continue;const j=await req(who,`/models/${m.id}/json`);equal(safe(JSON.parse(utf.decode(j.bytes))),m.document);const b=await req(who,`/models/${m.id}/export`);assert(/application\/xml/.test(b.headers['content-type']||''));assert(b.bytes.length>0);models++;results.push({kind:'full_model_json_equal_bpmn_captured',project,id:m.id,json_sha256:sha(j.bytes),bpmn_sha256:sha(b.bytes),bpmn_exact_oracle:'OPEN'});}
 }
 assert.equal(logs,20);assert.equal(models,before.models.size);
 save(path.join(out,'full-http-private-witness.json'),{status:'FULL_RECOVERY_HTTP_CAPTURED_PENDING_DELTA',before_sha256:c.before.sha256.toLowerCase(),operations,logins,results});
 const result={status:'FOUR_LEGACY_LOGINS_ALL20_ANALYSES_MODEL_JSON_CAPTURED_PENDING_DELTA',logs,models,role_open_checks:results.filter(r=>r.kind==='open_rbac').length,limits:['BPMN exact pureRust serializer oracle OPEN; full XML retained','Log derived view/calendar/warnings/provenance fields OPEN; normalized analysis and stored metadata compared','Write-role matrix/C08 destructive recovery OPEN','Whole Auth/session/version and otherrows delta must pass separately','No C18/R3 acceptance by this probe']};save(path.join(out,'full-http-summary.json'),result);console.log(JSON.stringify(result));
}
main().catch(()=>{console.error('full_recovery_http_failed_retained');process.exitCode=1;});
