'use strict';
// Pure byte-stream oracle. Caller MUST bind expected PRE SHA/bytes to its actual
// complete native PRE capture proof obtained BEFORE Apply. No SQL/CLI invocation.
const fs=require('node:fs'),crypto=require('node:crypto'),assert=require('node:assert/strict');
assert.equal(process.argv.length,7,'input plan output EXPECTED_PRE_SHA256 EXPECTED_PRE_BYTES');
const [input,planPath,output,expectedShaText,expectedBytesText]=process.argv.slice(2);
assert.match(expectedShaText,/^[a-fA-F0-9]{64}$/);
assert.match(expectedBytesText,/^[1-9][0-9]{0,9}$/);
const expectedSha=expectedShaText.toLowerCase(),expectedBytes=Number(expectedBytesText);
// Decimal600MB lower bound intentionally admits actual614MB full PRE; upper1GiB.
assert.ok(Number.isSafeInteger(expectedBytes)&&expectedBytes>=600000000&&expectedBytes<=1073741824);
const planStat=fs.statSync(planPath);assert.ok(planStat.isFile()&&planStat.size>0&&planStat.size<=4194304);
const planBytes=fs.readFileSync(planPath);assert.equal(planBytes.length,planStat.size);assert.ok(planBytes.length<=4194304);
const text=new TextDecoder('utf8',{fatal:true}).decode(planBytes).replace(/^\uFEFF/,'');
// Exact JSON number tokens; never route an i64 source_version through JS Number.
// Full parser also rejects duplicate keys, malformed/trailing JSON and deep input.
class NumberToken{constructor(raw){this.raw=raw;}}
function parseExact(s){
 let i=0;const ws=()=>{while(/[\x20\x09\x0a\x0d]/.test(s[i]||'x'))i++;};
 function string(){const start=i++;for(;i<s.length;i++){if(s[i]==='\\'){i++;continue;}if(s[i]==='"'){i++;return JSON.parse(s.slice(start,i));}}throw Error('plan_unterminated_string');}
 function value(depth){
  assert.ok(depth<=128,'plan_depth');ws();const c=s[i];
  if(c==='"')return string();
  if(c==='{'){i++;const out=Object.create(null);ws();if(s[i]==='}'){i++;return out;}while(true){assert.equal(s[i],'"');const k=string();assert.ok(!Object.hasOwn(out,k),'plan_duplicate_key');ws();assert.equal(s[i++],':');out[k]=value(depth+1);ws();const end=s[i++];if(end==='}')return out;assert.equal(end,',');ws();}}
  if(c==='['){i++;const out=[];ws();if(s[i]===']'){i++;return out;}while(true){out.push(value(depth+1));ws();const end=s[i++];if(end===']')return out;assert.equal(end,',');}}
  for(const [literal,result] of [['true',true],['false',false],['null',null]])if(s.startsWith(literal,i)){i+=literal.length;return result;}
  const match=/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(s.slice(i));assert.ok(match,'plan_number_or_value');i+=match[0].length;return new NumberToken(match[0]);
 }
 const result=value(0);ws();assert.equal(i,s.length,'plan_trailing');return result;
}
const plan=parseExact(text);assert.ok(plan&&typeof plan==='object'&&!Array.isArray(plan));
assert.ok(Array.isArray(plan.candidates));assert.equal(plan.candidates.length,10);
const prefixes=plan.candidates.map(c=>{
 assert.ok(c&&typeof c==='object'&&!Array.isArray(c));assert.equal(typeof c.key,'string');assert.match(c.key,/^repository\/project-[a-f0-9]+$/);assert.ok(Buffer.byteLength(c.key)<=512);
 assert.ok(c.source_version instanceof NumberToken,'exact_i64_token_required');const version=c.source_version.raw;
 assert.match(version,/^[1-9][0-9]*$/);assert.ok(BigInt(version)<=9223372036854775807n,'i64_version_bound');
 return {prefix:Buffer.from('["kv", '+JSON.stringify(c.key)+', '+JSON.stringify(version)+', '),key:c.key,seen:0};
});
assert.equal(new Set(prefixes.map(p=>p.key)).size,10);
let inf,outf;
const inputHash=crypto.createHash('sha256'),outputHash=crypto.createHash('sha256');
let inputBytes=0,outputBytes=0,prefix=Buffer.alloc(0),decision=null,lines=0,removed=0;
function write(b){if(!b.length)return;let offset=0;while(offset<b.length){const n=fs.writeSync(outf,b,offset,b.length-offset);assert.ok(n>0,'oracle_short_write');offset+=n;}outputHash.update(b);outputBytes+=b.length;}
function decide(){
 const row=prefixes.find(p=>prefix.subarray(0,p.prefix.length).equals(p.prefix));
 if(row){if(++row.seen!==1)throw Error('duplicate_candidate_row');decision='drop';removed++;}
 else{if(prefix.subarray(0,21).toString().startsWith('["kv", "repository/'))throw Error('unknown_or_changed_legacy_row');decision='keep';write(prefix);}
 prefix=Buffer.alloc(0);
}
try{
 inf=fs.openSync(input,'r');const stat=fs.fstatSync(inf);assert.ok(stat.isFile());assert.equal(stat.size,expectedBytes,'prior_native_pre_length_binding');
 outf=fs.openSync(output,'wx',0o600);
 const buffer=Buffer.alloc(65536);
 while(true){
  const read=fs.readSync(inf,buffer,0,buffer.length,null);if(!read)break;
  const b=buffer.subarray(0,read);inputHash.update(b);inputBytes+=read;if(inputBytes>expectedBytes)throw Error('full_pre_grew');
  let o=0;
  while(o<b.length){
   const newline=b.indexOf(10,o),end=newline<0?b.length:newline+1;let piece=b.subarray(o,end);
   if(decision===null){const take=Math.min(1024-prefix.length,piece.length);prefix=Buffer.concat([prefix,piece.subarray(0,take)]);piece=piece.subarray(take);if(prefix.length===1024||newline>=0)decide();}
   if(decision==='keep')write(piece);
   if(newline>=0){if(decision===null)throw Error('oracle_line_decision');lines++;if(lines>130)throw Error('full_pre_extra_line');decision=null;prefix=Buffer.alloc(0);}
   o=end;
  }
 }
 if(decision!==null||prefix.length)throw Error('missing_final_newline');
 const preSha=inputHash.digest('hex');
 if(inputBytes!==expectedBytes||preSha!==expectedSha||fs.fstatSync(inf).size!==expectedBytes)throw Error('full_pre_binding');
 if(lines!==130||removed!==10||lines-removed!==120||prefixes.some(p=>p.seen!==1))throw Error('full_candidate_row_and_line_binding');
 fs.fsyncSync(outf);
 process.stdout.write(JSON.stringify({status:'FULL_POST_ORACLE_DERIVED',pre_bytes:inputBytes,pre_sha256:preSha,post_bytes:outputBytes,post_sha256:outputHash.digest('hex'),pre_lines:lines,post_lines:lines-removed,removed_exact_rows:removed,scope:'Complete current native PRE byte stream bound by caller-supplied prior proof SHA/length; only exact ten plan KV key/version rows omitted; all other raw bytes/newlines/order preserved; not a migration oracle'})+'\n');
}finally{if(inf!==undefined)fs.closeSync(inf);if(outf!==undefined)fs.closeSync(outf);}

// Source preparation is NOT execution. Partial output is retained on failure and
// cannot be used without native0/fullEOF + FULL_POST_ORACLE_DERIVED proof. No old
// C2 hardcoded9959 digest or guessed post-state credit. Independent QA must first
// establish all130 current PRE rows/forward transform from original79AE capture
// and its actual Rust replay; this helper proves only the permitted10KV removal.
