'use strict';
// SOURCE ONLY. Read-only complete ACL snapshot oracle, no database/network/children.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex'),utf=new TextDecoder('utf8',{fatal:true});
const root=path.resolve(__dirname,'../../.local/sprint14');
function owned(p){p=path.resolve(p);const r=path.relative(root,p);assert(r&&!r.startsWith('..')&&!path.isAbsolute(r));for(let q=p;q!==root;q=path.dirname(q))assert(!fs.lstatSync(q).isSymbolicLink());return p;}
function read(p,cap){const s=fs.lstatSync(p);assert(s.isFile()&&!s.isSymbolicLink()&&s.size<=cap);return fs.readFileSync(p);}
const canonical=v=>v===null||typeof v!=='object'?JSON.stringify(v):Array.isArray(v)?'['+v.map(canonical).join(',')+']':'{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+canonical(v[k])).join(',')+'}';
function snapshot(p){const b=read(owned(p.path),33554432);assert.equal(sha(b),p.sha256.toLowerCase());assert.equal(b.length,p.bytes);assert.equal(b.at(-1),10);const rows=new Map(),columns=new Set();let target,targetRow;const lines=utf.decode(b).trimEnd().split('\n');assert(lines.length<=60000);
 for(const line of lines){const a=JSON.parse(line);assert(Array.isArray(a));let key;
  if(a[0]==='target_function'){assert(!target&&a.length===8);target=a;key='target_function';}
  else if(a[0]==='acl_columns'){assert.equal(a.length,5);const name=a.slice(1,4).join('.');assert(!columns.has(name));columns.add(name);key=canonical(a);}
  else if(a[0]==='acl_row'){assert.equal(a.length,5);assert.equal(a[1],'pg_catalog');assert(a[4]&&typeof a[4]==='object');const identity=structuredClone(a[4]);assert(Object.hasOwn(identity,a[3]));delete identity[a[3]];key=canonical([a[0],a[1],a[2],a[3],identity]);}
  else if(a[0]==='roles'){assert.equal(a.length,2);assert(!Object.hasOwn(a[1],'rolpassword'));key=canonical(['roles',a[1].oid]);}
  else if(a[0]==='memberships'){assert.equal(a.length,2);key=canonical(a);}
  else if(a[0]==='security_metadata'){assert.equal(a.length,3);assert(['pg_policy','pg_seclabel','pg_shseclabel','pg_shdepend','pg_db_role_setting'].includes(a[1]));key=canonical(a);}
  else throw Error('unexpected_acl_row');assert(!rows.has(key));rows.set(key,{a,line});
 }
 assert(target&&['pg_control_system()','pg_catalog.pg_control_system()'].includes(target[2])&&target[5].proname==='pg_control_system'&&target[5].pronargs===0);assert.equal(String(target[5].oid),target[1]);assert.equal(String(target[5].proowner),target[3]);assert(Array.isArray(target[6])&&typeof target[7]==='boolean');
 // tag/OID/regprocedure signature/ownerOID/ownerName/fullpg_proc/effectiveACL/appEXECUTE.
 for(const [k,v] of rows)if(v.a[0]==='acl_row'&&v.a[2]==='pg_proc'&&v.a[3]==='proacl'&&String(v.a[4].oid)===target[1]){assert(!targetRow);targetRow={key:k,row:v.a[4]};}
 assert(targetRow);assert.deepEqual(targetRow.row,target[5]);for(const name of ['pg_proc.proacl','pg_class.relacl','pg_attribute.attacl','pg_namespace.nspacl','pg_type.typacl','pg_language.lanacl','pg_database.datacl','pg_default_acl.defaclacl','pg_init_privs.initprivs'])assert(columns.has('pg_catalog.'+name));
 return {rows,columns,target,targetRow,sha256:sha(b),bytes:b.length};
}
function unchanged(a,b){assert.equal(a.sha256,b.sha256);assert.equal(a.bytes,b.bytes);}
function main(){assert.equal(process.argv.length,3);const cb=read(owned(process.argv[2]),1048576);assert.equal(sha(cb),process.env.PI_IDENTITY_DENIED_CONFIG_SHA);const c=JSON.parse(utf.decode(cb));assert.equal(c.scope,'s14-new-synthetic-identity-denial');assert.equal(c.source_db,'pi_restore_s14_identity_source01');assert.equal(c.restore_db,'pi_restore_s14_identity_restore01');
 const before=snapshot(c.source_before),after=snapshot(c.source_setup),restoreBefore=snapshot(c.restore_before),restoreSetup=snapshot(c.restore_setup);unchanged(restoreBefore,restoreSetup);assert.deepEqual(before.columns,after.columns);assert.equal(before.target[7],true);assert.equal(after.target[7],false);
 const b=before.target,a=after.target;assert.deepEqual(a.slice(0,5),b.slice(0,5));const br=structuredClone(b[5]),ar=structuredClone(a[5]);delete br.proacl;delete ar.proacl;assert.deepEqual(ar,br);assert(a[5].proacl!==null&&Array.isArray(a[5].proacl));
 const publicGrants=b[6].filter(x=>x.grantee==='0'&&x.privilege_type==='EXECUTE');assert.equal(publicGrants.length,1);const expectedEffective=b[6].filter(x=>!(x.grantee==='0'&&x.privilege_type==='EXECUTE'));assert.deepEqual(a[6],expectedEffective);assert(expectedEffective.some(x=>x.grantee===b[3]&&x.privilege_type==='EXECUTE'));
 // Every raw catalog ACL row/field except this one proacl must remain byte exact.
 before.rows.delete('target_function');after.rows.delete('target_function');const oldRow=before.rows.get(before.targetRow.key),newRow=after.rows.get(before.targetRow.key);assert(oldRow&&newRow);const expectedArray=structuredClone(oldRow.a);expectedArray[4].proacl=newRow.a[4].proacl;assert.deepEqual(newRow.a,expectedArray);before.rows.delete(before.targetRow.key);after.rows.delete(before.targetRow.key);assert.deepEqual(new Map([...after.rows].map(([k,v])=>[k,v.line])),new Map([...before.rows].map(([k,v])=>[k,v.line])));
 if(c.mode==='final'){unchanged(after,snapshot(c.source_after));unchanged(restoreBefore,snapshot(c.restore_after));}else assert.equal(c.mode,'setup');
 console.log(JSON.stringify({status:'EXACT_ONLY_SOURCE_FUNCTION_PUBLIC_EXECUTE_REMOVAL_PENDING_QA_TD',mode:c.mode,source_system_acl_rows:before.rows.size+2,restore_system_acl_rows:restoreBefore.rows.size,all_acl_columns:before.columns.size,pre_default_acl_null:b[5].proacl===null,public_execute_removed:1,owner_and_all_other_grants_preserved:true,all_other_raw_acl_fields_equal:true,restore_whole_acl_equal:true,limits:['Synthetic new fixture only; default pi_app baseline can execute identity','No product/default-security/C13/R3 acceptance','Source and restore wholemanaged/publiccatalog conservation proved separately by phase']}));}
try{main();}catch{console.error('identity_denied_acl_oracle_failed_retained');process.exitCode=1;}
