'use strict';
// Exact helper in a VM with virtual public byte streams. No disk output or PG.
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const file=path.resolve(__dirname,'../tools/sprint13/complete-post-oracle.cjs');
const source=fs.readFileSync(file,'utf8');
assert.equal(crypto.createHash('sha256').update(source).digest('hex'),'f15990c3cc4f88232776f6964e0749f30324d484abf3b744a6084a05c3865ee5');
const keys=Array.from({length:10},(_,i)=>'repository/project-'+String(i+1).padStart(32,'0'));
const versions=keys.map((_,i)=>i===9?'9223372036854775807':String(i+1));
const plan='{"candidates":['+keys.map((key,i)=>JSON.stringify({key}).slice(0,-1)+',"source_version":'+versions[i]+'}').join(',')+']}';
const candidates=keys.map((key,i)=>'["kv", '+JSON.stringify(key)+', '+JSON.stringify(versions[i])+', {"public":"value"}]\n');
const ordinary=Array.from({length:119},(_,i)=>'["record", '+JSON.stringify('public-'+i)+', "1", {"value":"é\\n"}]\n').join('');
const prefix=Buffer.from(candidates.join('')+ordinary+'["kv", "fixture/keep", "3", {"large":"');
const suffix=Buffer.from('"}]\n'),fillBytes=600000000;
const length=prefix.length+fillBytes+suffix.length;
const block=Buffer.alloc(65536,65);
function digest(parts){const h=crypto.createHash('sha256');h.update(parts[0]);let left=fillBytes;while(left){const n=Math.min(left,block.length);h.update(block.subarray(0,n));left-=n;}h.update(parts[1]);return h.digest('hex');}
const expectedSha=digest([prefix,suffix]);
const expectedPost=digest([Buffer.from(ordinary+'["kv", "fixture/keep", "3", {"large":"'),suffix]);
let checks=0;
function run(name,options={},expectedError){
 const chunks=options.firstChunks||[],p=options.prefix||prefix,s=options.suffix||suffix;
 const size=p.length+fillBytes+s.length,planText=options.plan||plan;
 let position=0,readCount=0,written=0,closed=0,stdout='',writeCount=0;
 const hash=crypto.createHash('sha256');
 const fake={
  statSync(){return {isFile:()=>true,size:Buffer.byteLength(planText)};},
  readFileSync(){return Buffer.from(planText);},
  openSync(name,mode){if(name==='input'){assert.equal(mode,'r');return 1;}assert.equal(name,'output');assert.equal(mode,'wx');return 2;},
  fstatSync(fd){assert.equal(fd,1);return {isFile:()=>true,size};},
  readSync(fd,b,offset,max){
   assert.equal(fd,1);let n=Math.min(max,size-position,chunks[readCount++]||max);if(n===0)return 0;
   let done=0;
   while(done<n){const at=position+done;let end;if(at<p.length){end=Math.min(n-done,p.length-at);p.copy(b,offset+done,at,at+end);}else if(at<p.length+fillBytes){end=Math.min(n-done,p.length+fillBytes-at);b.fill(65,offset+done,offset+done+end);}else{const k=at-p.length-fillBytes;end=Math.min(n-done,s.length-k);s.copy(b,offset+done,k,k+end);}done+=end;}
   if(options.mutateAt!==undefined&&position<=options.mutateAt&&position+n>options.mutateAt)b[offset+options.mutateAt-position]^=1;
   position+=n;return n;
  },
  writeSync(fd,b,offset,n){assert.equal(fd,2);const take=options.shortWrites&&writeCount++<4?Math.max(1,Math.floor(n/2)):n;hash.update(b.subarray(offset,offset+take));written+=take;return take;},
  fsyncSync(fd){assert.equal(fd,2);},closeSync(){closed++;}
 };
 const argv=['node','helper','input','plan','output',options.expectedSha||expectedSha,String(options.expectedBytes||size)];
 const context={require:n=>n==='node:fs'?fake:require(n),Buffer,TextDecoder,process:{argv,stdout:{write:v=>{stdout+=v;}}}};
 let error;try{vm.runInNewContext(source,context,{timeout:45000,filename:file});}catch(e){error=e;}
 if(expectedError){assert(error,name+' must refuse');assert.match(String(error),expectedError,name);assert.equal(stdout,'',name+' no success output');}
 else{assert.ifError(error);const result=JSON.parse(stdout);assert.equal(result.pre_lines,130);assert.equal(result.post_lines,120);assert.equal(result.removed_exact_rows,10);assert.equal(result.pre_sha256,expectedSha);assert.equal(result.post_sha256,expectedPost);assert.equal(hash.digest('hex'),expectedPost);assert.equal(result.post_bytes,written);assert.equal(closed,2);}
 checks++;return {name,virtual_bytes:size,actual_disk_output_bytes:0};
}
const results=[];
results.push(run('complete-all-bytes-max-i64'));
results.push(run('prefix-newline-utf8-split-and-short-writes',{firstChunks:[1,2,3,7,31,63,127,257,509,1023,65535],shortWrites:true}));
results.push(run('one-byte-kept-value-mutation',{mutateAt:prefix.length+12345},/full_pre_binding/));
results.push(run('prior-native-sha-mismatch',{expectedSha:'0'.repeat(64)},/full_pre_binding/));
results.push(run('prior-native-length-mismatch',{expectedBytes:length+1},/prior_native_pre_length_binding/));
results.push(run('duplicate-candidate-row',{prefix:Buffer.from(candidates[0]+prefix.toString())},/duplicate_candidate_row/));
results.push(run('candidate-version-changed',{prefix:Buffer.from(prefix.toString().replace('["kv", "'+keys[0]+'", "1",','["kv", "'+keys[0]+'", "2",'))},/unknown_or_changed_legacy_row/));
results.push(run('candidate-missing',{prefix:Buffer.from(prefix.toString().slice(Buffer.byteLength(candidates[0])))},/full_pre_binding|full_candidate_row/));
results.push(run('missing-final-newline',{suffix:Buffer.from('"}]')},/missing_final_newline/));
results.push(run('duplicate-plan-key',{plan:plan.replace('"source_version":1','"source_version":1,"source_version":1')},/plan_duplicate_key/));
results.push(run('plan-version-over-i64',{plan:plan.replace('9223372036854775807','9223372036854775808')},/i64_version_bound/));
results.push(run('plan-version-fraction',{plan:plan.replace('"source_version":1','"source_version":1.5')},/AssertionError/));
results.push(run('small-pre-refused',{expectedBytes:599999999},/AssertionError/));
process.stdout.write(JSON.stringify({status:'EXACT_HELPER_VIRTUAL_STREAM_REGRESSION',checks,results,limits:['Virtual public streams and fake filesystem; no actual native SQL capture or cleanup acceptance','Every positive stream hashes all600MB; no real large test file created']})+'\n');
