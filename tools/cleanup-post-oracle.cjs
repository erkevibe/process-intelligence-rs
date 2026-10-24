'use strict';
// Independently derives POST bytes from complete PRE by removing only the
// exact ten original plan KV rows. Does not issue SQL or invoke the CLI.
const fs=require('node:fs'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const [input,planPath,output]=process.argv.slice(2);
const plan=JSON.parse(fs.readFileSync(planPath,'utf8'));
assert.equal(plan.candidates.length,10);
const prefixes=plan.candidates.map(c=>{
 assert.match(c.key,/^repository\/project-[a-f0-9]+$/);
 assert.ok(Number.isSafeInteger(c.source_version)&&c.source_version>0);
 return {prefix:Buffer.from('["kv", '+JSON.stringify(c.key)+', '+JSON.stringify(String(c.source_version))+', '),key:c.key,seen:0};
});
assert.equal(new Set(prefixes.map(p=>p.key)).size,10);
const inf=fs.openSync(input,'r'),outf=fs.openSync(output,'wx',0o600);
const inputHash=crypto.createHash('sha256'),outputHash=crypto.createHash('sha256');
let inputBytes=0,outputBytes=0,prefix=Buffer.alloc(0),decision=null,lines=0,removed=0;
const write=b=>{if(!b.length)return;fs.writeSync(outf,b);outputHash.update(b);outputBytes+=b.length;};
function decide(){
 const row=prefixes.find(p=>prefix.subarray(0,p.prefix.length).equals(p.prefix));
 if(row){if(++row.seen!==1)throw Error('duplicate_candidate_row');decision='drop';removed++;}
 else{if(prefix.subarray(0,21).toString().startsWith('["kv", "repository/'))throw Error('unknown_or_changed_legacy_row');decision='keep';write(prefix);}
 prefix=Buffer.alloc(0);
}
try{
 const buffer=Buffer.alloc(65536);
 while(true){
  const read=fs.readSync(inf,buffer,0,buffer.length,null);if(!read)break;
  const b=buffer.subarray(0,read);inputHash.update(b);inputBytes+=read;
  let o=0;
  while(o<b.length){
   const newline=b.indexOf(10,o),end=newline<0?b.length:newline+1;let piece=b.subarray(o,end);
   if(decision===null){
    const take=Math.min(1024-prefix.length,piece.length);prefix=Buffer.concat([prefix,piece.subarray(0,take)]);piece=piece.subarray(take);
    if(prefix.length===1024||newline>=0)decide();
   }
   if(decision==='keep')write(piece);
   if(newline>=0){if(decision===null)throw Error('oracle_line_decision');lines++;decision=null;prefix=Buffer.alloc(0);}
   o=end;
  }
 }
 if(decision!==null||prefix.length)throw Error('missing_final_newline');
 const preSha=inputHash.digest('hex');
 if(inputBytes!==614304123||preSha!=='9959d3e9e746460c0c52853d139dcbccff37ee230907537ab437fcfe33933da1')throw Error('full_pre_binding');
 if(removed!==10||prefixes.some(p=>p.seen!==1))throw Error('full_candidate_row_binding');
 fs.fsyncSync(outf);
 process.stdout.write(JSON.stringify({status:'FULL_POST_ORACLE_DERIVED',pre_bytes:inputBytes,pre_sha256:preSha,post_bytes:outputBytes,post_sha256:outputHash.digest('hex'),pre_lines:lines,removed_exact_rows:removed,scope:'Complete byte stream, only exact original ten KV key/version rows omitted; all other raw bytes preserved'})+'\n');
}finally{fs.closeSync(inf);fs.closeSync(outf);}
