'use strict';
// SOURCE-ONLY draft. Normal HTTP against one NEW restored S13 runtime only.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex'),utf=new TextDecoder('utf8',{fatal:true});
const clone=x=>JSON.parse(JSON.stringify(x)),eq=(a,b)=>assert.deepEqual(a,b),form=x=>new URLSearchParams(x);
const id=/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/,project=/^project-[a-f0-9]{32}$/;
const workspace=path.resolve(__dirname,'../..'),privateRoot=path.join(workspace,'.local','sprint13');
function bounded(file,cap=1024*1024){const s=fs.lstatSync(file);assert(s.isFile()&&!s.isSymbolicLink()&&s.size<=cap);return fs.readFileSync(file);}
function within(file){const p=path.resolve(file),rel=path.relative(privateRoot,p);assert(rel&&!rel.startsWith('..')&&!path.isAbsolute(rel));let cur=p;while(cur!==privateRoot){assert(!fs.lstatSync(cur).isSymbolicLink());cur=path.dirname(cur);}return p;}
let written=0;function save(file,value){const b=Buffer.isBuffer(value)?value:Buffer.from(JSON.stringify(value,null,2));assert(b.length<=2*1024*1024);written+=b.length;assert(written<=256*1024*1024);const fd=fs.openSync(file,'wx');try{fs.writeFileSync(fd,b);fs.fsyncSync(fd);}finally{fs.closeSync(fd);}}
// Extract exact raw payload JSON token: no reserialization of repository values.
function rootTokens(bytes){
 const text=utf.decode(bytes);JSON.parse(text);let i=0;const out=new Map(),ws=()=>{while(/[\x20\x09\x0a\x0d]/.test(text[i]||'x'))i++;};
 function str(){const start=i++;for(;i<text.length;i++){if(text[i]==='\\'){i++;continue;}if(text[i]==='"'){i++;return text.slice(start,i);}}throw Error('json_string');}
 function val(){const start=i;if(text[i]==='"'){str();return text.slice(start,i);}if(text[i]==='{'||text[i]==='['){const st=[text[i++]];while(st.length){assert(i<text.length);const c=text[i];if(c==='"'){str();continue;}if(c==='{'||c==='[')st.push(c);else if(c==='}'||c===']')assert.equal(st.pop(),c==='}'?'{':'[');i++;}return text.slice(start,i);}while(i<text.length&&!/[\x20\x09\x0a\x0d,}]/.test(text[i]))i++;assert(i>start);return text.slice(start,i);}
 ws();assert.equal(text[i++],'{');ws();while(text[i]!=='}'){const k=JSON.parse(str());assert(!out.has(k));ws();assert.equal(text[i++],':');ws();out.set(k,val());ws();if(text[i]===','){i++;ws();continue;}assert.equal(text[i],'}');}i++;ws();assert.equal(i,text.length);return out;
}
function canonical(value){if(value===null||typeof value!=='object')return JSON.stringify(value);if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';}
async function main(){
 assert.equal(process.argv.length,3);const configPath=within(process.argv[2]),configBytes=bounded(configPath);
 assert.equal(sha(configBytes),process.env.PI_PROJECT_LIST_PROBE_CONFIG_SHA);const c=JSON.parse(utf.decode(configBytes));
 assert.equal(c.scope,'s13-new-restored-project-list-rbac');assert.equal(c.app_port,3097);assert.equal(c.pg_port,5465);assert.equal(c.version,'0.7.3');assert(/^pi_restore_s13_[a-z0-9_]{1,35}$/.test(c.database));
 const out=within(c.output_directory);assert(fs.statSync(out).isDirectory());const creds=JSON.parse(utf.decode(bounded(within(c.credentials_private),65536)));
 const roles=['owner','editor','viewer','foreign'];eq(Object.keys(creds).sort(),[...roles].sort());
 for(const r of roles){eq(Object.keys(creds[r]).sort(),['password','username']);assert(typeof creds[r].username==='string'&&typeof creds[r].password==='string');assert(typeof c.actor_ids[r]==='string'&&c.actor_ids[r]);}
 assert(Array.isArray(c.projects)&&c.projects.length===2&&new Set(c.projects).size===2&&c.projects.every(p=>project.test(p)));
 const admissionBytes=bounded(within(c.runtime_admission.path));assert.equal(sha(admissionBytes),c.runtime_admission.sha256.toLowerCase());const admission=JSON.parse(utf.decode(admissionBytes));
 assert.equal(admission.scope,'S13_NEW_RESTORED_PROJECT_LIST_RUNTIME_REVIEWED');assert.equal(admission.database,c.database);assert.equal(admission.app_port,3097);assert.equal(admission.pg_port,5465);assert.equal(admission.version,'0.7.3');assert.equal(admission.app_sha256,c.app_sha256);assert(admission.app_pid>0);
 // ACL/NTFS/native image/Job/PG identity must be independently proved by launcher.
 // This probe checks its bound record and /health, not native facts by assertion.
 const client=path.join(__dirname,'..','owned-http-client.cjs');assert.equal(sha(bounded(client)),c.http_client_sha.toLowerCase());const {ownedHttp}=require(client);
 const requiredPins=['src/auth_project_list.rs','src/project_list.rs','src/platform.rs','src/auth.rs','src/audit.rs','tools/sprint13/project-list-rbac-probe.cjs','tools/owned-http-client.cjs'].map(p=>path.resolve(workspace,p));
 eq(c.source_pins.map(p=>path.resolve(p.path)).sort(),requiredPins.sort());for(const pin of c.source_pins){assert.equal(sha(bounded(pin.path)),pin.sha256.toLowerCase());}
 const end=Math.min(Date.now()+600000,Date.parse(c.deadline_utc));assert(Number.isFinite(end)&&end>Date.now()&&end<=Date.parse('2026-10-19T19:44:42Z'));
 const cookies={},requests=[],cases=[];let serial=0;
 const allowed=route=>route==='/health'||route==='/login'||route==='/project-list/json'||route==='/project-list/folders'||route==='/audit/export'||route==='/backup'||/^\/project-list\/folders\/[a-f0-9-]{36}\/(rename|move|archive|unarchive|delete)$/.test(route)||/^\/projects\/project-[a-f0-9]{32}\/(open|move)$/.test(route);
 async function req(who,route,method='GET',fields,expected=200){
  assert(allowed(route));assert(serial<3000&&Date.now()<end);const headers={};if(cookies[who])headers.Cookie=cookies[who];if(method==='POST')headers.Origin='http://127.0.0.1:3097';
  const body=fields===undefined?undefined:form(fields);if(body)assert(Buffer.byteLength(body.toString())<=4096);
  const before=new Date().toISOString(),response=await ownedHttp({port:3097,route,method,headers,body,maxBytes:2*1024*1024,timeoutMs:Math.max(1,Math.min(15000,end-Date.now()))});
  const after=new Date().toISOString(),name='list-http-'+String(++serial).padStart(4,'0');save(path.join(out,name+'.body'),response.bytes);
  const set=response.headers['set-cookie'];if(set){assert.equal(route,'/login');assert.equal(set.length,1);assert(/^pi_session=[a-f0-9]+;/.test(set[0]));cookies[who]=set[0].split(';')[0];}
  const row={actor:who,route,method,status:response.status,expected,before,after,bytes:response.bytes.length,sha256:sha(response.bytes),body_file:name+'.body',location:response.headers.location||null};requests.push(row);save(path.join(out,name+'.json'),row);assert.equal(response.status,expected);
  if(expected===303)assert.equal(row.location,route.endsWith('/open')?'/logs':'/projects');
  return {...row,json:()=>JSON.parse(utf.decode(response.bytes)),bytes:response.bytes};
 }
 const health=(await req(null,'/health')).json();assert.equal(health.version,'0.7.3');
 for(const who of roles){await req(who,'/login','POST',creds[who],303);assert(cookies[who]);}
 for(const who of ['owner','editor','viewer'])await req(who,`/projects/${c.projects[0]}/open`,'POST',{},303);
 const foreignList=(await req('foreign','/project-list/json')).json();assert(!foreignList.projects.some(p=>c.projects.includes(p.id)));
 const foreignProjects=foreignList.projects.filter(p=>p.role==='owner'&&!p.archived);assert.equal(foreignProjects.length,1);
 await req('foreign',`/projects/${foreignProjects[0].id}/open`,'POST',{},303);
 const initialActorAudit={};for(const who of roles){const a=(await req(who,'/audit/export')).json();assert.equal(a.project_id,who==='foreign'?foreignProjects[0].id:c.projects[0]);if(who==='viewer'||who==='editor'){assert.equal(a.auth_owner_projection.total,0);eq(a.auth_owner_projection.entries,[]);}initialActorAudit[who]=a;}
 function checkView(v){
  eq(Object.keys(v).sort(),['folders','project_folders','projects','revision']);assert(Number.isSafeInteger(v.revision)&&v.revision>=0);
  for(const f of v.folders){eq(Object.keys(f).sort(),f.archived===undefined?['id','name','owner_id','parent_id']:['archived','id','name','owner_id','parent_id']);assert(id.test(f.id));assert(typeof f.name==='string'&&typeof f.owner_id==='string');assert(f.parent_id===null||id.test(f.parent_id));assert(f.archived===undefined||f.archived===true);}
  for(const p of v.projects){eq(Object.keys(p).sort(),['archived','folder_id','id','name','revision','role']);assert(project.test(p.id));assert(['owner','editor','viewer'].includes(p.role));assert(Number.isSafeInteger(p.revision)&&p.revision>0);}for(const [p,f] of Object.entries(v.project_folders))assert(v.projects.some(x=>x.id===p)&&id.test(f));
 }
 async function snapshot(){
  const views={},audits={},payloads={};for(const who of roles){views[who]=(await req(who,'/project-list/json')).json();checkView(views[who]);}
  for(const p of c.projects){await req('owner',`/projects/${p}/open`,'POST',{},303);const b=await req('owner','/backup'),tokens=rootTokens(b.bytes);eq([...tokens.keys()].sort(),['digest_sha256','payload','schema_version','source_project_id']);assert.equal(JSON.parse(tokens.get('source_project_id')),p);assert.equal(JSON.parse(tokens.get('schema_version')),1);const raw=Buffer.from(tokens.get('payload'));assert.equal(sha(raw),JSON.parse(tokens.get('digest_sha256')));payloads[p]={sha256:sha(raw),bytes:raw.length};audits[p]=(await req('owner','/audit/export')).json();assert.equal(audits[p].project_id,p);assert.equal(audits[p].schema_version,2);eq(Object.keys(audits[p]).sort(),['auth_owner_projection','deletion_owner_projection','project_dropped','project_entries','project_id','project_total','schema_version','scope']);assert(audits[p].auth_owner_projection.total<400);}
  await req('owner',`/projects/${c.projects[0]}/open`,'POST',{},303);return {views,audits,payloads};
 }
 let state=await snapshot();const initial=clone(state);save(path.join(out,'list-http-initial.json'),state);
 for(const who of roles){if(who!=='owner')assert(state.views[who].folders.every(f=>f.owner_id===c.actor_ids.owner));}
 for(const p of c.projects){assert.equal(state.views.owner.projects.find(x=>x.id===p).role,'owner');assert.equal(state.views.editor.projects.find(x=>x.id===p).role,'editor');assert.equal(state.views.viewer.projects.find(x=>x.id===p).role,'viewer');}
 const folder=(v,key)=>v.folders.find(f=>f.id===key),projectAt=(v,key)=>v.projects.find(p=>p.id===key);
 function expectedViews(before,ownerAfter){
  const result=clone(before.views),catalog=new Map(ownerAfter.folders.map(f=>[f.id,f]));
  for(const who of roles){const v=result[who];v.revision=ownerAfter.revision;
   for(const p of v.projects){const ownerProject=projectAt(ownerAfter,p.id);if(ownerProject){p.revision=ownerProject.revision;p.folder_id=ownerProject.folder_id;}}
   v.project_folders=Object.fromEntries(Object.entries(ownerAfter.project_folders).filter(([p])=>v.projects.some(x=>x.id===p)));
   const visible=new Set(ownerAfter.folders.filter(f=>f.owner_id===c.actor_ids[who]).map(f=>f.id));
   for(const destination of Object.values(v.project_folders)){let cur=destination;while(cur){assert(catalog.has(cur));visible.add(cur);cur=catalog.get(cur).parent_id;}}
   v.folders=ownerAfter.folders.filter(f=>visible.has(f.id));
  }return result;
 }
 function auditExpected(before,after,action,resource,revision,parameters,response,scope){
  for(const p of c.projects){const b=before.audits[p],a=clone(after.audits[p]);if(p!==scope){eq(a,b);continue;}
   const trail=a.auth_owner_projection,old=b.auth_owner_projection;assert.equal(trail.total,old.total+1);assert.equal(trail.visible_entries,old.visible_entries+1);assert.equal(trail.dropped,old.dropped);eq(trail.entries.slice(0,-1),old.entries);
   const e=trail.entries.at(-1);eq(Object.keys(e).sort(),['action','actor','at','outcome','policy','project','resources','revision','sequence']);assert.equal(e.sequence,old.total+1);assert.equal(e.actor,c.actor_ids.owner);assert.equal(e.project,scope);assert.equal(e.action,action);eq(e.resources,[resource]);assert.equal(e.revision,revision);assert.equal(e.outcome,'committed');assert(Date.parse(e.at)>=Date.parse(response.before)&&Date.parse(e.at)<=Date.parse(response.after));
   eq(e.policy,{version:1,rule:action==='project_moved'?'owner_project_list_placement_cas_v1':'creator_current_writer_project_list_catalog_cas_v1',parameters_sha256:sha(Buffer.from(canonical(parameters)))});
   a.auth_owner_projection=clone(old);eq(a,b);
  }
 }
 async function reject(label,who,route,fields,status,code){const before=clone(state),r=await req(who,route,'POST',fields,status);assert.equal(r.json().code,code);state=await snapshot();eq(state,before);cases.push({label,status,code,full_http_projection_conserved:true,whole_auth_sql_oracle:'PENDING_QA'});}
 async function mutate(label,route,fields,action,resource,parameters,edit,scope=c.projects[0]){
  const before=clone(state),r=await req('owner',route,'POST',fields,303),after=await snapshot(),expected=clone(before.views.owner);expected.revision++;
  const actualResource=edit(expected,after.views.owner,resource);eq(after.views,expectedViews(before,expected));eq(after.payloads,before.payloads);
  const params=parameters(actualResource),revision=action==='project_moved'?projectAt(expected,actualResource).revision:expected.revision;
  auditExpected(before,after,action,actualResource,revision,params,r,scope);state=after;cases.push({label,status:303,action,resource:actualResource,revision,parameters_sha256:sha(Buffer.from(canonical(params))),exact_public_delta:true,raw_payloads_unchanged:true});return actualResource;
 }
 async function create(name,parent=null){const rev=state.views.owner.revision;return mutate('create '+name,'/project-list/folders',{name,parent:parent||'',catalog_revision:rev},'project_list_folder_created',null,key=>({catalog_revision:rev,folder_id:key,parent,name_sha256:sha(Buffer.from(name.trim())),name_bytes:Buffer.byteLength(name.trim())}),(e,a)=>{const fresh=a.folders.filter(f=>!e.folders.some(x=>x.id===f.id));assert.equal(fresh.length,1);const f={id:fresh[0].id,name:name.trim(),owner_id:c.actor_ids.owner,parent_id:parent};assert(id.test(f.id));e.folders.push(f);e.folders.sort((x,y)=>x.id<y.id?-1:x.id>y.id?1:0);return f.id;});}
 async function change(key,operation,extra,action,edit,params){const rev=state.views.owner.revision;return mutate(operation,`/project-list/folders/${key}/${operation}`,{catalog_revision:rev,...extra},action,key,k=>({catalog_revision:rev,folder_id:k,...params}),e=>{edit(e);return key;});}
 async function moveProject(p,destination){const rev=state.views.owner.revision,pr=projectAt(state.views.owner,p).revision,old=state.views.owner.project_folders[p]||null;await mutate('project placement',`/projects/${p}/move`,{catalog_revision:rev,project_revision:pr,destination:destination||''},'project_moved',p,()=>({catalog_revision:rev,project_revision:pr,old_folder:old,destination,membership_unchanged:true,payload_unchanged:true}),e=>{const target=projectAt(e,p);target.revision++;target.folder_id=destination;if(destination)e.project_folders[p]=destination;else delete e.project_folders[p];return p;},p);}
 const a=await create('S13 List A'),b=await create('S13 List B'),child=await create('S13 List Child',a);
 for(const who of ['editor','viewer','foreign']){
  for(const op of ['rename','move','archive','unarchive','delete'])await reject(who+' foreign-folder '+op,who,`/project-list/folders/${a}/${op}`,{catalog_revision:state.views.owner.revision,...(op==='rename'?{name:'forbidden'}:op==='move'?{parent:b}:{})},403,'access_denied');
  await reject(who+' foreign placement',who,`/projects/${c.projects[0]}/move`,{catalog_revision:state.views.owner.revision,project_revision:projectAt(state.views.owner,c.projects[0]).revision,destination:b},403,'access_denied');
  await reject(who+' foreign parent',who,'/project-list/folders',{catalog_revision:state.views.owner.revision,name:'forbidden parent',parent:a},403,'access_denied');
 }
 await reject('stale catalog','owner',`/project-list/folders/${a}/rename`,{catalog_revision:state.views.owner.revision-1,name:'stale'},409,'project_list_conflict');
 await reject('stale project','owner',`/projects/${c.projects[0]}/move`,{catalog_revision:state.views.owner.revision,project_revision:projectAt(state.views.owner,c.projects[0]).revision-1,destination:b},409,'project_conflict');
 await reject('name no-op','owner',`/project-list/folders/${a}/rename`,{catalog_revision:state.views.owner.revision,name:'S13 List A'},422,'project_list_no_change');
 await reject('nonempty folder','owner',`/project-list/folders/${a}/delete`,{catalog_revision:state.views.owner.revision},422,'project_list_not_empty');
 await reject('cycle','owner',`/project-list/folders/${a}/move`,{catalog_revision:state.views.owner.revision,parent:child},422,'project_list_invalid');
 await reject('blank name','owner','/project-list/folders',{catalog_revision:state.views.owner.revision,name:'   '},422,'project_list_invalid');
 await reject('UTF8 name bytes','owner','/project-list/folders',{catalog_revision:state.views.owner.revision,name:'я'.repeat(101)},422,'project_list_invalid');
 await reject('duplicate siblings','owner','/project-list/folders',{catalog_revision:state.views.owner.revision,name:'S13 List A'},422,'project_list_invalid');
 await reject('missing parent','owner','/project-list/folders',{catalog_revision:state.views.owner.revision,name:'missing',parent:'00000000-0000-4000-8000-000000000000'},422,'project_list_invalid');
 await change(a,'rename',{name:'S13 List Renamed'},'project_list_folder_renamed',e=>{folder(e,a).name='S13 List Renamed';},{name_sha256:sha(Buffer.from('S13 List Renamed')),name_bytes:Buffer.byteLength('S13 List Renamed')});
 await change(child,'move',{parent:b},'project_list_folder_moved',e=>{folder(e,child).parent_id=b;},{old_parent:a,parent:b});
 await moveProject(c.projects[0],child);await moveProject(c.projects[0],a);await moveProject(c.projects[1],b);
 await reject('placement no-op','owner',`/projects/${c.projects[1]}/move`,{catalog_revision:state.views.owner.revision,project_revision:projectAt(state.views.owner,c.projects[1]).revision,destination:b},422,'project_list_no_change');
 await change(b,'archive',{},'project_list_folder_archived',e=>{folder(e,b).archived=true;},{archived:true,projects_access_unchanged:true});
 await reject('archived ancestor destination','owner',`/projects/${c.projects[0]}/move`,{catalog_revision:state.views.owner.revision,project_revision:projectAt(state.views.owner,c.projects[0]).revision,destination:child},422,'project_list_invalid');
 await moveProject(c.projects[1],null);
 await change(b,'unarchive',{},'project_list_folder_restored',e=>{delete folder(e,b).archived;},{archived:false,projects_access_unchanged:true});
 await change(a,'archive',{},'project_list_folder_archived',e=>{folder(e,a).archived=true;},{archived:true,projects_access_unchanged:true});
 await reject('archived destination','owner',`/projects/${c.projects[1]}/move`,{catalog_revision:state.views.owner.revision,project_revision:projectAt(state.views.owner,c.projects[1]).revision,destination:a},422,'project_list_invalid');
 await reject('archived parent','owner','/project-list/folders',{catalog_revision:state.views.owner.revision,name:'blocked',parent:a},422,'project_list_invalid');
 await moveProject(c.projects[0],null);
 await change(a,'unarchive',{},'project_list_folder_restored',e=>{delete folder(e,a).archived;},{archived:false,projects_access_unchanged:true});
 await change(child,'delete',{},'project_list_folder_deleted',e=>{e.folders=e.folders.filter(f=>f.id!==child);},{empty_required:true,cascade:false});
 await change(a,'delete',{},'project_list_folder_deleted',e=>{e.folders=e.folders.filter(f=>f.id!==a);},{empty_required:true,cascade:false});
 // Exact depth64 boundary requires 64 actual accepted mutations before one refusal.
 let parent=null;const chain=[];for(let n=1;n<=64;n++){parent=await create('S13 depth '+n,parent);chain.push(parent);}
 await reject('depth65','owner','/project-list/folders',{catalog_revision:state.views.owner.revision,name:'S13 depth 65',parent},422,'project_list_invalid');
 // Clean the NEW chain only, deepest first; original/foreign folders untouched.
 for(const key of chain.reverse())await change(key,'delete',{},'project_list_folder_deleted',e=>{e.folders=e.folders.filter(f=>f.id!==key);},{empty_required:true,cascade:false});
 eq(state.payloads,initial.payloads);for(const who of roles)for(const p of initial.views[who].projects){const current=state.views[who].projects.find(x=>x.id===p.id);assert(current);eq({...current,revision:p.revision,folder_id:p.folder_id},p);}
 for(const who of ['editor','viewer','foreign'])eq((await req(who,'/audit/export')).json(),initialActorAudit[who]);
 for(const pin of c.source_pins)assert.equal(sha(bounded(pin.path)),pin.sha256.toLowerCase());assert.equal(sha(bounded(client)),c.http_client_sha.toLowerCase());assert.equal(sha(bounded(configPath)),sha(configBytes));
 save(path.join(out,'project-list-http-final.json'),state);
 save(path.join(out,'project-list-rbac-result.json'),{status:'S13_PROJECT_LIST_HTTP_EVIDENCE_PENDING_QA_TD_SQL',cases,requests:requests.length,raw_payloads:state.payloads,initial_catalog_revision:initial.views.owner.revision,final_catalog_revision:state.views.owner.revision,limits:['NEW restored smallS runtime only; no C18/full historical credit','Whole Auth/session/member maps/all SQL tables/sequence conservation require separate QA snapshots','HTTP actor identity pinned from independent fixture Auth; cookie stays only in memory','No browser/render/Datastar interaction claim','No process/start/stop/database commands inside this probe','Editors/foreign current owners may create their own folders; target creator ownership is tested instead','All temporary depth mutations audited and retained; no action erased from history']});
 console.log(JSON.stringify({status:'S13_PROJECT_LIST_HTTP_EVIDENCE_PENDING_QA_TD_SQL',cases:cases.length,requests:requests.length}));
}
main().catch(()=>{console.error('project_list_probe_failed_retained');process.exitCode=1;});

/* Prospective contract: outer owner must check currentSID protected private NTFS
 * config/output/credentials, actual new0.7.3 package/source/EXE and ownedPG5465/
 * app3097 PID creation/image/Job/listeners/database identity; no old servers.
 * Config SHA is supplied only via PI_PROJECT_LIST_PROBE_CONFIG_SHA; exact config
 * fields: scope,version,app_port,pg_port,database,output_directory,credentials_private,
 * actor_ids owner/editor/viewer/foreign, projects[2],app_sha256,http_client_sha,
 * runtime_admission{path,sha256},source_pins[{path,sha256}],deadline_utc.
 * Source pins MUST include current auth_project_list/project_list/platform/auth/
 * audit plus this draft and maintained HTTP helper; independent exact launch review.
 * Only normal login/open/list/folderCRUD/projectmove/backup/auditGET allowlist.
 * max600sec/3000requests/4096requestbytes/2MiBresponse/256MiBnewoutput. Full finite
 * HTTP bodies privately retained CreateNew/fsync; cookies/passwords never logged.
 * Exact payload token SHA checked against actual Rust digest before compare; this
 * proves accessible project payload equality, not member-map/wholeAuth equality.
 * Strict visible-list deltas and audit prefix+one exact actor/project/resource/
 * revision/time/outcome/policy digest; schema2 export all other fields unchanged.
 * Domain422 / stale409 / access403 checked from actual JSON code, never inferred.
 * No source edits/hooks, SQL, child launch, imports of old lifecycle harnesses.
 * This file has NOT been run or parsed as an executable during preparation.
 */
