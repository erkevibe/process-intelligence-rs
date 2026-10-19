'use strict';
// Finite new SMALL-S constructor; no original historical or independent-QA acceptance claim.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const utf=new TextDecoder('utf8',{fatal:true});
function write(file,value){const fd=fs.openSync(file,'wx');try{fs.writeFileSync(fd,typeof value==='string'||Buffer.isBuffer(value)?value:JSON.stringify(value,null,2));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}}
// Preserve the exact UTF8 JSON value token span. Never stringify a parsed payload/Auth.
function rootValues(bytes){
 const text=utf.decode(bytes);JSON.parse(text);let i=0;const values=new Map();
 const ws=()=>{while(/[\x20\x09\x0a\x0d]/.test(text[i]||'x'))i++;};
 function string(){const start=i++;for(;i<text.length;i++){if(text[i]==='\\'){i++;continue;}if(text[i]==='"'){i++;return text.slice(start,i);}}throw Error('json_string');}
 function value(){const start=i;if(text[i]==='"'){string();return text.slice(start,i);}if(text[i]==='{'||text[i]==='['){const stack=[text[i++]];while(stack.length){assert(i<text.length);const c=text[i];if(c==='"'){string();continue;}if(c==='{'||c==='[')stack.push(c);else if(c==='}'||c===']'){assert.equal(stack.pop(),c==='}'?'{':'[');}i++;}return text.slice(start,i);}while(i<text.length&&!/[\x20\x09\x0a\x0d,}]/.test(text[i]))i++;assert(i>start);return text.slice(start,i);}
 ws();assert.equal(text[i++],'{');ws();while(text[i]!=='}'){assert.equal(text[i],'"');const key=JSON.parse(string());assert(!values.has(key),'duplicate root key');ws();assert.equal(text[i++],':');ws();values.set(key,value());ws();if(text[i]===','){i++;ws();continue;}assert.equal(text[i],'}');}i++;ws();assert.equal(i,text.length);return values;
}
function read(file,cap=8*1024*1024){assert(fs.statSync(file).size<=cap);return fs.readFileSync(file);}
async function httpSeed(c){
 const client=path.join(__dirname,'..','owned-http-client.cjs');assert.equal(hash(read(client)),c.http_client_sha.toLowerCase());const {ownedHttp}=require(client);
 assert.equal(c.pg_port,5465);assert.equal(c.app_port,3097);assert.equal(c.database,'process_intelligence');
 const out=c.output_directory,actors={},requests=[];let serial=0;
 const form=x=>new URLSearchParams(x);
 async function request(who,route,method='GET',body,expected=200){
  assert(/^\/(health|setup|users|login|project-list\/(json|folders)|projects(?:\/[a-z0-9-]+\/(open|members|move))?|xes\/(preview|import|previews\/[a-f0-9-]+\/report)|models\/import|backup)$/.test(route));
  const headers={};if(method==='POST')headers.Origin='http://127.0.0.1:3097';if(who&&actors[who]?.cookie)headers.Cookie=actors[who].cookie;
  const before=new Date().toISOString(),r=await ownedHttp({port:3097,route,method,body,headers,maxBytes:2*1024*1024,timeoutMs:15000});
  const label='seed-http-'+String(++serial).padStart(3,'0');write(path.join(out,label+'.body'),r.bytes);
  const cookies=r.headers['set-cookie'];assert(!cookies||cookies.length===1);if(cookies&&who){assert(/^pi_session=[a-f0-9]+;/.test(cookies[0]));actors[who].cookie=cookies[0].split(';')[0];}
  const row={route,method,status:r.status,expected,location:r.headers.location||null,before,after:new Date().toISOString(),bytes:r.bytes.length,sha256:hash(r.bytes),body:label+'.body'};requests.push(row);write(path.join(out,label+'.json'),row);assert.equal(r.status,expected);
  return {...row,bytes:r.bytes,text:utf.decode(r.bytes),json:()=>JSON.parse(utf.decode(r.bytes))};
 }
 const health=(await request(null,'/health')).json();assert.equal(health.version,'0.7.3');
 const password=crypto.randomBytes(24).toString('hex');for(const who of ['owner','editor','viewer','foreign'])actors[who]={username:'s13small'+who,password};
 await request('owner','/setup','POST',form({username:actors.owner.username,password}),303);
 for(const who of ['editor','viewer','foreign'])await request('owner','/users','POST',form({username:actors[who].username,password}),303);
 const xes=read(c.manual_xes,32768);assert.equal(hash(xes),c.manual_xes_sha.toLowerCase());
 const bpmn=read(c.model_bpmn,32768);assert.equal(hash(bpmn),c.model_bpmn_sha.toLowerCase());
 const targets=[];
 for(const [index,name] of ['S13 Small A','S13 Small B'].entries()){
  await request('owner','/projects','POST',form({name}),303);let list=(await request('owner','/project-list/json')).json();const found=list.projects.filter(p=>p.name===name);assert.equal(found.length,1);const id=found[0].id;assert(/^project-[a-f0-9]{32}$/.test(id));
  await request('owner',`/projects/${id}/open`,'POST',form({}),303);
  for(const who of ['editor','viewer'])await request('owner',`/projects/${id}/members`,'POST',form({username:actors[who].username,role:who}),303);
  const upload=new FormData();upload.set('file',new Blob([xes]),'manual.xes');const preview=await request('owner','/xes/preview','POST',upload);
  const tokens=[...preview.text.matchAll(/name="token"[^>]*value="([a-f0-9-]+)"/g)];assert(tokens.length>=1&&new Set(tokens.map(v=>v[1])).size===1);const token=tokens[0][1];
  const report=(await request('owner',`/xes/previews/${token}/report`)).json();assert.equal(report.source_sha256,c.manual_xes_sha.toLowerCase());assert.equal(report.source_events,10);assert.equal(report.source_cases,4);assert.deepEqual(report.changes,[]);
  const imported=await request('owner','/xes/import','POST',form({token,consent:'yes'}),303);assert(/^\/logs\/log-[0-9]+$/.test(imported.location));
  const modelUpload=new FormData();modelUpload.set('file',new Blob([bpmn]),'linear.bpmn');const model=await request('owner','/models/import','POST',modelUpload,303);assert(/^\/models\/model-[0-9]+$/.test(model.location));
  if(index===0){list=(await request('owner','/project-list/json')).json();await request('owner','/project-list/folders','POST',form({name:'S13 Small catalog',parent:'',catalog_revision:list.revision}),303);list=(await request('owner','/project-list/json')).json();const folders=list.folders.filter(f=>f.name==='S13 Small catalog');assert.equal(folders.length,1);const project=list.projects.find(p=>p.id===id);await request('owner',`/projects/${id}/move`,'POST',form({destination:folders[0].id,catalog_revision:list.revision,project_revision:project.revision}),303);}
  const bundle=await request('owner','/backup'),parts=rootValues(bundle.bytes);assert.deepEqual([...parts.keys()].sort(),['digest_sha256','payload','schema_version','source_project_id']);assert.equal(JSON.parse(parts.get('source_project_id')),id);assert.equal(JSON.parse(parts.get('schema_version')),1);
  const payload=Buffer.from(parts.get('payload'));assert.equal(hash(payload),JSON.parse(parts.get('digest_sha256')),'exact actual Rust payload serialization hash');
  const parsed=JSON.parse(parts.get('payload'));assert.equal(Object.keys(parsed.logs).length,1);assert.equal(Object.keys(parsed.models).length,1);
  const file='small-project-'+(index+1)+'.payload.json';write(path.join(out,file),payload);targets.push({id,version:index===0?7:11,payload:file,payload_sha256:hash(payload),log_id:imported.location.split('/').at(-1),model_id:model.location.split('/').at(-1)});
 }
 for(const who of ['editor','viewer','foreign']){await request(who,'/login','POST',form({username:actors[who].username,password}),303);if(who!=='foreign')await request(who,`/projects/${targets[0].id}/open`,'POST',form({}),303);}
 const catalog=(await request('owner','/project-list/json')).json();assert(catalog.revision>0&&catalog.folders.length>0);assert.equal(catalog.project_folders[targets[0].id],catalog.folders.find(f=>f.name==='S13 Small catalog').id);
 // Retain random synthetic credentials privately for later restore-login/RBAC tests.
 // Cookies remain in memory; no credential is included in stdout or public evidence.
 write(path.join(out,'small-credentials-private.json'),Object.fromEntries(Object.entries(actors).map(([who,a])=>[who,{username:a.username,password:a.password}])));
 write(path.join(out,'small-http-construction.json'),{status:'ACTUAL_MAINTAINED_HTTP_INPUTS_PENDING_NATIVE_AND_INDEPENDENT_REVIEW',targets,requests,public_inputs:{xes_sha:c.manual_xes_sha,bpmn_sha:c.model_bpmn_sha},catalog_revision:catalog.revision,limits:['Synthetic smallS only, not historical corpus','No browser/Datastar or standalone RBAC acceptance claim']});
}
function assemble(c){
 const out=c.output_directory,record=JSON.parse(utf.decode(read(path.join(out,'small-http-construction.json')))),normal=read(path.join(out,'normal-offline.stdout'));
 const fields=rootValues(normal),a=JSON.parse(fields.get('auth')),sequence=JSON.parse(fields.get('sequence')),authVersion=JSON.parse(fields.get('auth_version'));assert(/^[1-9][0-9]*$/.test(authVersion));assert(BigInt(authVersion)<=9223372036854775807n);
 assert.equal(Object.values(a.users).length,4);assert(a.project_list.revision>0&&Object.keys(a.project_list.project_folders).length>0);
 assert(sequence.is_called===true||sequence.is_called===false);assert(/^[1-9][0-9]*$/.test(sequence.last_value));assert(BigInt(sequence.last_value)<=9223372036854775807n);
 const source=read(c.migrations_source,1024*1024);assert.equal(hash(source),c.migrations_source_sha.toLowerCase());
 const text=utf.decode(source),matches=[...text.matchAll(/const MIGRATION: &str = "([^"\\]+)";/g)];assert.equal(matches.length,1);const checksum=hash(Buffer.from(matches[0][1]));
 const baseline=utf.decode(read(c.baseline_sql,32768));assert.equal(hash(Buffer.from(baseline)),c.baseline_sql_sha.toLowerCase());
 const ddl=baseline.slice(0,baseline.indexOf('INSERT INTO public.pi_schema_migrations')).replace(/^--[^\n]*(?:\n|$)/gm,'').split(';').map(s=>s.trim()).filter(Boolean);
 const actual=matches[0][1].split(';').map(s=>s.trim().replace('IF NOT EXISTS ','')).filter(Boolean);assert.deepEqual(ddl,actual,'maintained baseline actual DDL matches pinned source literal');
 const literal=s=>{assert(!s.includes('\0'));return "'"+s.replaceAll("'","''")+"'";};
 let sql="SET standard_conforming_strings=on; SET client_encoding='UTF8';\nBEGIN;\nDELETE FROM public.pi_kv WHERE key='sprint11/retained-sentinel';\n";
 sql+=`INSERT INTO public.pi_kv(key,version,document) VALUES('auth',${authVersion},${literal(fields.get('auth'))}::jsonb);\n`;
 for(const target of record.targets){const bytes=read(path.join(out,target.payload));assert.equal(hash(bytes),target.payload_sha256);assert(/^project-[a-f0-9]{32}$/.test(target.id));assert(a.projects[target.id]);const key='repository/'+target.id;sql+=`INSERT INTO public.pi_kv(key,version,document) VALUES(${literal(key)},${target.version},${literal(utf.decode(bytes))}::jsonb);\n`;}
 sql+="INSERT INTO public.pi_kv(key,version,document) VALUES('fixture/keep',3,'{\"a\":1,\"b\":[true,null,\"é\"]}'::jsonb);\n";
 sql+=`SELECT setval('public.pi_resource_sequence',${sequence.last_value},${sequence.is_called?'true':'false'});\nCOMMIT;\n`;
 write(path.join(out,'assemble-v1-private.sql'),sql);write(path.join(out,'baseline-checksum.txt'),checksum);
 write(path.join(out,'small-assembly-provenance.json'),{status:'SYNTHETIC_SMALL_S_CONSTRUCTION_NOT_HISTORICAL',baseline_checksum:checksum,migrations_source_sha:c.migrations_source_sha,baseline_sql_sha:c.baseline_sql_sha,targets:record.targets,declared_sequence_transform:{logical_last_value:sequence.last_value,is_called:sequence.is_called,source_native_log_cnt:sequence.log_cnt,assembled_log_cnt:'0',method:'maintained setval resets internal counter; no nextval replay',definition:sequence.definition},auth_byte_transfer:'Raw actual source JSON token -> private escaped SQL -> jsonb; no JS/PS document reserialization'});
}
function verify(c){
 const out=c.output_directory,pre=JSON.parse(utf.decode(read(path.join(out,'assembled-v1-pre.stdout')))),post=JSON.parse(utf.decode(read(path.join(out,'migrated-small-post.stdout')))),normal=JSON.parse(utf.decode(read(path.join(out,'normal-offline.stdout')))),record=JSON.parse(utf.decode(read(path.join(out,'small-http-construction.json'))));
 const same=(a,b)=>assert.deepEqual(a,b);
 const preKv=new Map(pre.kv.map(r=>[r.key,r])),postKv=new Map(post.kv.map(r=>[r.key,r]));assert.equal(pre.kv.length,4);same(pre.kv,post.kv);assert.equal(pre.ledger.length,1);assert.equal(post.ledger.length,2);same(pre.ledger[0],post.ledger[0]);same(pre.sequence,post.sequence);assert.equal(pre.sequence.log_cnt,'0');same(pre.sequence.last_value,normal.sequence.last_value);same(pre.sequence.is_called,normal.sequence.is_called);same(pre.sequence.definition,normal.sequence.definition);same(preKv.get('auth').document,normal.auth);assert.equal(String(preKv.get('auth').version),normal.auth_version);
 assert.equal(post.projects.length,2);assert.equal(post.markers.length,2);assert.equal(post.records.length,10);const candidates=[];
 for(const target of record.targets){const retained=preKv.get('repository/'+target.id);assert.equal(retained.version,target.version);same(retained,postKv.get(retained.key));const header=post.projects.find(p=>p.project_id===target.id),marker=post.markers.find(m=>m.project_id===target.id),records=post.records.filter(r=>r.project_id===target.id);assert(header&&marker);assert.equal(marker.source_version,target.version);assert.equal(marker.source_sha,target.payload_sha256);assert.equal(marker.checksum,post.ledger[1].checksum);same(records.map(r=>r.kind).sort(),['log_analysis','log_data','log_source','log_state','model']);assert.equal(header.document.log_ids.length,1);assert.equal(header.document.model_ids.length,1);same(header.document.log_ids,[target.log_id]);same(header.document.model_ids,[target.model_id]);
  const payload=JSON.parse(utf.decode(read(path.join(out,target.payload)))),log=payload.logs[target.log_id];for(const [kind,field]of [['log_data','data'],['log_analysis','analysis']])same(records.find(r=>r.kind===kind).document,log[field]);same(records.find(r=>r.kind==='log_source').document,log.provenance?{source_envelope_version:1,source:log.source,provenance:log.provenance}:log.source);same(records.find(r=>r.kind==='model').document,payload.models[target.model_id]);const stateExpected={};for(const key of ['id','filename','analysis_version','view_revision','threshold','selected','selected_case','elapsed_ms','source_sha256','order','filters','calendar','project_id'])stateExpected[key]=log[key];if(log.created_at)stateExpected.created_at=log.created_at;same(records.find(r=>r.kind==='log_state').document,stateExpected);
  const expectedHeader={current:payload.current,sequence:payload.sequence,user_views:payload.user_views,durable_jobs:payload.durable_jobs,log_ids:Object.keys(payload.logs).sort(),model_ids:Object.keys(payload.models).sort()};if(payload.organization&&(Object.keys(payload.organization.folders||{}).length||Object.keys(payload.organization.assignments||{}).length))expectedHeader.organization=payload.organization;if(payload.audit?.total||payload.audit?.entries?.length)expectedHeader.audit=payload.audit;same(header.document,expectedHeader);assert.equal(header.version,target.version);assert(records.every(r=>r.version===1));
  candidates.push({key:retained.key,source_version:target.version,source_sha:marker.source_sha,checksum:marker.checksum});
 }
 const a=postKv.get('auth').document;assert(a.project_list.revision>0);same(a.project_list,normal.auth.project_list);same(postKv.get('fixture/keep'),{key:'fixture/keep',version:3,document:{a:1,b:[true,null,'é']}});
 write(path.join(out,'small-fixture-construction.json'),{status:'SMALL_S_CONSTRUCTION_EVIDENCE_PENDING_QA_TD',candidates,all_record_kinds:true,normal_auth:true,project_list_exercised:true,generic_key:'fixture/keep',sequence:post.sequence,full_pre_sha:hash(read(path.join(out,'assembled-v1-pre.stdout'))),full_post_sha:hash(read(path.join(out,'migrated-small-post.stdout'))),limits:['Pure JS parsed equality only supplemental; exact raw KV/sequence SQL hashes must match from phase','Header/record forward transform needs independent QA oracle before input-review status','Synthetic maintained smallS, no full historical credit']});
}
async function main(){assert.equal(process.argv.length,4);const bytes=read(process.argv[2],1024*1024);assert.equal(hash(bytes),process.env.PI_SMALL_SEED_CONFIG_SHA);const c=JSON.parse(utf.decode(bytes));assert.equal(c.scope,'s13-maintained-small-seed');const mode=process.argv[3];if(mode==='http')await httpSeed(c);else if(mode==='assemble')assemble(c);else if(mode==='verify')verify(c);else throw Error('seed_probe_mode');}
if(require.main===module)main().catch(()=>{process.stderr.write('Small seed STOP; inspect private retained evidence.\n');process.exitCode=1;});
module.exports={rootValues};
