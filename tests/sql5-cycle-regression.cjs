'use strict';
// Replay production parser functions at prepare.rs's pipelined boundary.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const source=fs.readFileSync('tools/sql5-stream-observer.cjs','utf8');
const start=source.indexOf('function frontend(f)'),end=source.indexOf('function backendStream()');
assert.ok(start>0&&end>start);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const sql='SELECT 1',events=[],sent=[];
const context=vm.createContext({Buffer,TextDecoder,Error,Number,Math,Set,Map,clearTimeout,sha,events,sent,sqlHash:sha(Buffer.from(sql))});
const declarations=[
"const utf=new TextDecoder('utf8',{fatal:true}),TARGET='target',FRONT_MAX=1048576;",
"const allowedParse=new Set([sqlHash]),allowedSimple=new Map(),keys=[];",
"const cfg={mode:'observe'},statements=new Map(),portals=new Map(),responses=[],descriptions=[],commands=[],syncs=[];",
"let startupReady=true,frontendCycle=1,backendCycle=1,heldE,heldS,released=false,target57014=false,selected,bindWritten,armed=false,pid=1,targetExecutions=0,targetRows=0,targetCompleted=false,timer,terminated=false;",
"const backend={},client={};function arm(){}function send(s,b,c,cb){sent.push(b);if(cb)cb();}",
"function event(kind,data={}){events.push({kind,...data});}function stop(reason){throw Error(reason);}",
"function str(b,o=0){const e=b.indexOf(0,o);if(e<0)throw Error('cstring_stop');return [utf.decode(b.subarray(o,e)),e+1];}"
].join('\n');
vm.runInContext(declarations+'\n'+source.slice(start,end)+"\nglobalThis.api={frontend,control,queues:{responses,descriptions,commands,syncs},state:()=>({frontendCycle,backendCycle})};",context);
const {api}=context;
function frame(type,body=Buffer.alloc(0)){const h=Buffer.alloc(5);h[0]=type.charCodeAt(0);h.writeUInt32BE(body.length+4,1);return Buffer.concat([h,body]);}
function prepare(name){api.frontend(frame('P',Buffer.concat([Buffer.from(name+'\0'+sql+'\0'),Buffer.alloc(2)])));api.frontend(frame('D',Buffer.from('S'+name+'\0')));api.frontend(frame('S'));}
function prepared(){api.control('1',Buffer.alloc(0));api.control('t',Buffer.alloc(2));api.control('T',Buffer.alloc(2));}
prepare('s1');prepared();prepare('s2');
assert.equal(api.queues.responses.length,1);
api.control('Z',Buffer.from('I'));
assert.equal(api.queues.responses.length,1,'later ParseComplete expectation preserved');
assert.equal(api.queues.descriptions.length,1,'later description preserved');
assert.equal(api.state().backendCycle,2);
prepared();api.control('Z',Buffer.from('I'));
assert.equal(api.state().backendCycle,3);
assert.equal(api.queues.responses.length,0);
assert.throws(()=>api.control('Z',Buffer.from('I')),/unexpected_ready_stop/);
const timeout=Buffer.from('C57014\0Mcanceling statement due to statement timeout\0\0');
api.queues.commands.push({target:true,cycle:4});
api.control('E',timeout);
assert.equal(events.at(-1).target_execution,false,'future target is not current error');
assert.equal(api.queues.commands.length,1,'future target survives current error');
api.queues.commands.pop();
api.queues.commands.push({target:true,cycle:3});
assert.throws(()=>api.control('E',timeout),/57014_unproven_target_phase_stop/);
api.queues.commands.pop();
prepare('s3');
assert.throws(()=>api.control('Z',Buffer.from('I')),/unfinished_cycle_stop/);
assert.equal(api.queues.syncs[0],3,'failed boundary remains retained');
assert.throws(()=>api.control('2',Buffer.alloc(0)),/backend_completion_map_stop/);
assert.equal(events.filter(e=>e.kind==='actual_cycle_complete').length,2);
assert.equal(events.find(e=>e.kind==='actual_cycle_complete').pending_later_responses,1);
process.stdout.write(JSON.stringify({status:'FINITE_CYCLE_REGRESSION_PASSED',observer_sha256:sha(Buffer.from(source)),scenarios:['pipelined next prepare retained','next exact cycle completed','unexpected Z refused','future target not associated with current error','unproven target timeout refused','unfinished current cycle refused','wrong completion refused'],limits:['Parser regression, not live SQL compatibility']})+'\n');
