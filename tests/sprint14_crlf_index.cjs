'use strict';
// Offline regression for the Windows native-row / PostgreSQL value::text domain.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {index}=require('../tools/sprint14/historical-write-state.cjs');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
async function main(){
 assert.equal(process.argv.length,3);const root=path.resolve(__dirname,'../.local/sprint14'),out=path.resolve(process.argv[2]);
 const rel=path.relative(root,out);assert(rel&&!rel.startsWith('..')&&!path.isAbsolute(rel)&&!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
 const realNow=Date.now;Date.now=()=>Date.parse('2026-10-20T04:00:00Z');let cases=0;
 try{
  const auth=JSON.stringify(['kv','auth','1',{users:{},projects:{},sessions:{}}]);
  async function run(name,lines,ending,mode='full'){
   const b=Buffer.from(lines.join(ending)+ending),p=path.join(out,name+'.jsonl');assert(b.length<262144);fs.writeFileSync(p,b,{flag:'wx'});
   return index({input:{path:p,bytes:b.length,sha256:sha(b)},mode,deadline_utc:'2026-10-20T09:54:16Z'});
  }
  for(const crOffset of [65535,65536,65537]){
   const empty=JSON.stringify(['kv','qa/boundary','1','']),n=crOffset-Buffer.byteLength(auth)-2-Buffer.byteLength(empty);assert(n>0);
   const row=JSON.stringify(['kv','qa/boundary','1','x'.repeat(n)]),expected={bytes:Buffer.byteLength(row),sha256:sha(Buffer.from(row))};
   for(const [ending,label] of [['\r\n','crlf'],['\n','lf']]){
    const full=await run(label+crOffset,[auth,row],ending),summary=await run('summary-'+label+crOffset,[auth,JSON.stringify(['hashed',['kv','qa/boundary'],String(expected.bytes),expected.sha256])],ending,'summary');
    assert.equal(full.count,2);assert.deepEqual(full.rows.map(r=>[r.key,r.bytes,r.sha256]),summary.rows.map(r=>[r.key,r.bytes,r.sha256]));
    assert.equal(full.rows[1].bytes,expected.bytes);assert.equal(full.rows[1].sha256,expected.sha256);cases++;
   }
  }
  const text=JSON.stringify(['kv','qa/unicode','1','é漢🙂\\r\r\n']);
  for(const [ending,label] of [['\r\n','crlf'],['\n','lf']]){const r=await run('unicode-'+label,[auth,text],ending);assert.equal(r.rows[1].sha256,sha(Buffer.from(text)));assert.equal(r.rows[1].bytes,Buffer.byteLength(text));cases++;}
  const p=path.join(out,'missing-lf.jsonl'),b=Buffer.from(auth);fs.writeFileSync(p,b,{flag:'wx'});await assert.rejects(index({input:{path:p,bytes:b.length,sha256:sha(b)},mode:'full',deadline_utc:'2026-10-20T09:54:16Z'}));cases++;
 }finally{Date.now=realNow;}
 console.log(JSON.stringify({status:'OFFLINE_NATIVE_CRLF_LF_STREAM_BOUNDARIES_REGRESSION_PASSED',cases,no_pg_or_runtime:true}));
}
main().catch(()=>{console.error('s14_crlf_regression_failed');process.exitCode=1;});
