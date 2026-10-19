'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{EventEmitter}=require('node:events');
const source=fs.readFileSync('tools/cleanup-boundary-observer.cjs','utf8');
const fragment=source.slice(source.indexOf('function str('),source.indexOf('function frontendFrames()'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const TARGET='DELETE FROM public.pi_kv k USING unnest($1::text[],$2::bigint[]) AS expected(key,version) WHERE k.key=expected.key AND k.version=expected.version RETURNING k.key,k.version';
const keys=Array.from({length:10},(_,i)=>'repository/project-'+String(i+1).padStart(32,'0')),versions=keys.map((_,i)=>String(i+1));
function frame(type,body=Buffer.alloc(0)){const h=Buffer.alloc(5);h[0]=type.charCodeAt(0);h.writeUInt32BE(body.length+4,1);return Buffer.concat([h,body]);}
function i16(n){const b=Buffer.alloc(2);b.writeUInt16BE(n);return b;}
function i32(n){const b=Buffer.alloc(4);b.writeInt32BE(n);return b;}
function array(oid,values){const h=Buffer.concat([i32(1),i32(0),i32(oid),i32(10),i32(1)]);return Buffer.concat([h,...values.map(v=>{const b=oid===25?Buffer.from(v):(()=>{const b=Buffer.alloc(8);b.writeBigInt64BE(BigInt(v));return b;})();return Buffer.concat([i32(b.length),b]);})]);}
function bind(values=versions,oid=25){const a=array(25,keys),b=array(20,values);a.writeInt32BE(oid,8);return frame('B',Buffer.concat([Buffer.from('\0delete\0'),i16(2),i16(1),i16(1),i16(2),i32(a.length),a,i32(b.length),b,i16(1),i16(1)]));}
function row(index){const k=Buffer.from(keys[index]),v=Buffer.alloc(8);v.writeBigInt64BE(BigInt(versions[index]));return Buffer.concat([i16(2),i32(k.length),k,i32(8),v]);}
function context(mode){
 const events=[],sentBackend=[],sentClient=[];
 const backend=new EventEmitter(),client=new EventEmitter();
 backend.writableLength=client.writableLength=0;
 backend.write=(b,cb)=>{sentBackend.push(Buffer.from(b));cb?.();return true;};
 client.write=(b,cb)=>{sentClient.push(Buffer.from(b));cb?.();return true;};
 for(const s of [backend,client]){s.pause=()=>{};s.resume=()=>{};}
 const ctx=vm.createContext({Buffer,TextDecoder,Error,Number,Math,Set,Map,clearTimeout,sha,keys,versions,TARGET,backend,client,events,process:{hrtime:process.hrtime}});
 const declarations=[
 "const utf=new TextDecoder('utf8',{fatal:true}),FRONT_MAX=1048576,QUEUE_MAX=2097152,ROW_MAX=268435456,CONTROL_MAX=65536;",
 "const cfg={mode:"+JSON.stringify(mode)+"},allowedParse=new Set(),allowedSimple=new Map([[sha(Buffer.from('COMMIT')),1]]),expectedPairs=new Map(keys.map((k,i)=>[k,versions[i]])),returnedPairs=new Set();",
 "const statements=new Map([['delete',{target:true,complete:true,parameters:2,returning_types_verified:true}]]),portals=new Map(),responses=[],descriptions=[],commands=[],syncs=[];",
 "let startupReady=true,frontendCycle=1,backendCycle=1,selected,bindWritten,terminated=false,targetExecutions=0,targetRows=0,targetCompleted=false,readyStatus='T',pendingCommit,commitForwarded=false,commitObserved=false,commitAckWithheld=false,pid=123,closed=false;",
 "function event(kind,data={}){events.push({kind,...data});}function stop(reason,code=2){event('stop',{reason,code});closed=true;}"
 ].join('\n');
 vm.runInContext(declarations+'\n'+fragment+"\nglobalThis.api={frontend,control,backendStream,setReady:(s)=>{readyStatus=s;},state:()=>({closed,targetRows,targetCompleted,commitForwarded,commitAckWithheld}),queues:{commands,responses,descriptions,syncs}};",ctx);
 return {api:ctx.api,backend,events,sentBackend,sentClient};
}
function started(c){
 c.api.frontend(bind());c.api.control('2',Buffer.alloc(0));
 c.api.frontend(frame('E',Buffer.concat([Buffer.from('\0'),i32(0)])));c.api.frontend(frame('S'));
}
function deleted(c){
 started(c);for(let i=0;i<10;i++)c.api.control('D',row(i));
 c.api.control('C',Buffer.from('DELETE 10\0'));c.api.control('Z',Buffer.from('T'));
}
const f02=context('f02');deleted(f02);f02.api.frontend(frame('Q',Buffer.from('COMMIT\0')));
assert.equal(f02.api.state().closed,true);assert.equal(f02.sentBackend.filter(b=>b[0]===81).length,0);
assert.ok(f02.events.some(e=>e.kind==='f02_original_commit_never_forwarded'&&e.returned_pairs===10));
const f03=context('f03');deleted(f03);f03.api.frontend(frame('Q',Buffer.from('COMMIT\0')));
assert.equal(f03.sentBackend.filter(b=>b[0]===81).length,1);
f03.api.backendStream();const ack=frame('C',Buffer.from('COMMIT\0'));
f03.backend.emit('data',ack.subarray(0,3));assert.equal(f03.sentClient.length,0);
f03.backend.emit('data',ack.subarray(3,7));assert.equal(f03.sentClient.length,0);
f03.backend.emit('data',ack.subarray(7));assert.equal(f03.sentClient.length,0);
assert.equal(f03.api.state().commitAckWithheld,true);
assert.ok(f03.events.some(e=>e.kind==='actual_complete_server_commit_frame_held'&&e.client_bytes_forwarded===0&&e.frame_sha===sha(ack)));
const early=context('f03');early.api.frontend(frame('Q',Buffer.from('COMMIT\0')));assert.equal(early.api.state().commitForwarded,false);assert.equal(early.api.state().closed,false);
const wrongPair=context('f02'),swapped=[...versions];[swapped[0],swapped[1]]=[swapped[1],swapped[0]];assert.throws(()=>wrongPair.api.frontend(bind(swapped)),/delete_bind_exact_pair_stop/);assert.equal(wrongPair.sentBackend.length,0);
const wrongOid=context('f02');assert.throws(()=>wrongOid.api.frontend(bind(versions,1043)),/delete_array_header_stop/);
const duplicate=context('f02');started(duplicate);duplicate.api.control('D',row(0));assert.throws(()=>duplicate.api.control('D',row(0)),/delete_returning_exact_pair_stop/);
const incomplete=context('f02');started(incomplete);assert.throws(()=>incomplete.api.control('C',Buffer.from('DELETE 10\0')),/target_completion_shape_stop/);
const wrongCycle=context('f02');started(wrongCycle);wrongCycle.api.queues.commands[0].cycle=99;assert.throws(()=>wrongCycle.api.control('D',row(0)),/delete_returning_phase_stop/);
const noTx=context('f03');noTx.api.setReady('I');assert.throws(()=>started(noTx),/delete_outside_actual_transaction_stop/);
const endedTx=context('f03');deleted(endedTx);endedTx.api.setReady('I');assert.throws(()=>endedTx.api.frontend(frame('Q',Buffer.from('COMMIT\0'))),/commit_without_actual_delete_stop/);
const staleReady=context('f03');deleted(staleReady);staleReady.api.frontend(frame('Q',Buffer.from('COMMIT\0')));staleReady.api.setReady('I');assert.throws(()=>staleReady.api.control('C',Buffer.from('COMMIT\0')),/commit_ack_outside_actual_transaction_stop/);assert.equal(staleReady.api.state().commitAckWithheld,false);
process.stdout.write(JSON.stringify({status:'FINITE_DELETE_COMMIT_PARSER_REGRESSION_PASSED',observer_sha256:sha(Buffer.from(source)),scenarios:11,limits:['Production parser functions with controlled protocol bytes; no actual PostgreSQL/F02/F03 credit','Fragmented COMMIT header/body withheld before client write exercised']})+'\n');
