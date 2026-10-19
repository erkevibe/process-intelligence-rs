'use strict';
const fs=require('node:fs'),path=require('node:path');
const [out,mode]=process.argv.slice(2);if(!['repo512','repo513','survivor512','survivor513'].includes(mode))throw Error('retention_compare_scope');
function load(file){if(fs.statSync(file).size>16*1024*1024)throw Error('retention_capture_bound');return fs.readFileSync(file,'utf8');}
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const key=r=>({kv:'1'+r[1],project:'2'+r[1],record:'3'+r[1]+'/'+r[2]+'/'+r[3],marker:'4'+r[1]?.project_id,ledger:'5'+r[1]?.version,sequence:'6',sequence_definition:'7'})[r[0]];
const sort=r=>r.sort((a,b)=>key(a)<key(b)?-1:key(a)>key(b)?1:0);
try{
 const expected=JSON.parse(load(path.join(out,mode+'.expected-full-state.json'))),actual=load(path.join(out,mode+'-post.stdout')).trim().split('\n').map(JSON.parse);
 if(!Array.isArray(expected)||!expected.some(r=>r[0]==='kv'&&r[1]==='auth')||!expected.some(r=>r[0]==='sequence_definition'))throw Error('retention_expected_incomplete');
 if(canonical(sort(expected))!==canonical(sort(actual)))throw Error('retention_unexpected_full_database_delta');
 const report=JSON.parse(load(path.join(out,mode+'-export.json'))),trail=mode.startsWith('repo')?{total:report.project_total,dropped:report.project_dropped,entries:report.project_entries}:report.deletion_owner_projection;
 const total=mode.endsWith('512')?512:513;
 if(trail.total!==total||trail.entries.length!==512||trail.dropped!==total-512||trail.entries.some((e,i)=>e.sequence!==total-511+i))throw Error('retention_boundary_or_sequence');
 process.stdout.write(JSON.stringify({status:'FULL_BOUNDARY_DATABASE_AND_RETENTION_VERIFIED',mode,total,retained:512,dropped:total-512,all_rows_compared:true})+'\n');
}catch(error){process.stderr.write(error.message+'\n');process.exitCode=1;}
