'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const out=process.argv[2],read=n=>JSON.parse(fs.readFileSync(path.join(out,n),'utf8'));
const rows=n=>fs.readFileSync(path.join(out,n),'utf8').trim().split('\n').map(JSON.parse);
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function check(ok,code){if(!ok)throw Error(code);}
try{
 const expected=rows('cas-pre.stdout'),actual=rows('cas-post.stdout'),http=read('cas-http-result.json');
 check(http.status==='STOCK_OVERLAPPING_HTTP_CAS_RESPONSES'&&http.records.length===2,'cas_http_proof');
 for(const r of http.records){const b=fs.readFileSync(path.join(out,r.body_file));check(b.length===r.bytes&&sha(b)===r.sha256,'cas_http_body_hash');}
 const winner=http.records.find(r=>r.status===303),loser=http.records.find(r=>r.status===409);check(winner&&loser,'cas_winner_loser');
 const a=expected.find(r=>r[0]==='kv'&&r[1]==='auth'),observed=actual.find(r=>r[0]==='kv'&&r[1]==='auth');
 const project=a[3].projects[http.project];check(project.members[http.actor]==='owner','cas_pre_owner');check((project.revision||1)===winner.revision,'cas_pre_revision');
 project.name=winner.name;project.revision=winner.revision+1;
 const trail=a[3].audit?.[http.project]||{total:0,entries:[]},last=observed[3].audit?.[http.project]?.entries.at(-1),at=last?.at;
 check(typeof at==='string'&&Date.parse(at)>=Date.parse(winner.started)&&Date.parse(at)<=Date.parse(winner.finished),'cas_audit_timestamp');
 const params={name_sha256:sha(winner.name),name_bytes:Buffer.byteLength(winner.name),expected_revision:winner.revision};
 const entry={sequence:trail.total+1,at,actor:http.actor,project:http.project,action:'project_renamed',resources:[http.project],revision:project.revision,
  policy:{version:1,rule:'owner_project_name_cas_v1',parameters_sha256:sha(canonical(params))},outcome:'committed'};
 a[3].audit??={};a[3].audit[http.project]={total:trail.total+1,entries:[...trail.entries,entry].slice(-512)};a[2]=String(BigInt(a[2])+1n);
 check(canonical(expected)===canonical(actual),'cas_unexpected_full_database_delta');
 fs.writeFileSync(path.join(out,'cas-expected-full-state.json'),canonical(expected),{flag:'wx'});
 process.stdout.write(JSON.stringify({status:'STOCK_CAS_FULL_PRE_DERIVED_STATE_VERIFIED',requests:2,commits:1,conflicts:1,all_rows_compared:true})+'\n');
}catch(e){process.stderr.write(e.message+'\n');process.exitCode=1;}
