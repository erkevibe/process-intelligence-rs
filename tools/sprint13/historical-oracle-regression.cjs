'use strict';
// Benign synthetic anti-false-PASS cases. No SQL or historical acceptance credit.
const assert=require('node:assert/strict'), fs=require('node:fs'), path=require('node:path');
const oracle=require('./historical-state-oracle.cjs');
const out=path.resolve(process.argv[2]||'');
assert.match(out.replace(/\\/g,'/'),/\/\.local\/sprint13\/root\/[a-z0-9-]+$/);
assert.ok(fs.statSync(out).isDirectory());
let checks=0;
const check=(fn)=>{fn();checks++;};
check(()=>assert.equal(oracle.valueDigest(oracle.parseExact('{"b":1.0,"a":[true,null,"é"]}')),oracle.valueDigest(oracle.parseExact('{"a":[true,null,"é"],"b":1e0}'))));
check(()=>assert.notEqual(oracle.valueDigest(oracle.parseExact('9007199254740992')),oracle.valueDigest(oracle.parseExact('9007199254740993'))));
check(()=>assert.equal(oracle.exactInteger(oracle.parseExact('9223372036854775807')),'9223372036854775807'));
for(const bad of ['{"a":1,"a":2}','{"a":true} trailing','[1,]','"\\ud800"','0e9999999']) check(()=>assert.throws(()=>oracle.parseExact(bad)));
check(()=>assert.throws(()=>oracle.captureEntry(oracle.parseExact('["unknown",1]'))));
check(()=>assert.throws(()=>oracle.captureEntry(oracle.parseExact('["kv","x",1,{}]'))));
check(()=>assert.throws(()=>oracle.captureEntry(oracle.parseExact('["sequence","63",0,true]'))));
const baseline=[
 '["kv","auth","1",{"users":{"u":{"name":"Ж"}},"sentinel":9007199254740993}]',
 '["kv","repository/p","7",{"logs":{"l":{"data":[1,true,null,"𐍈"]}}}]',
 '["project","p","7",{"log_ids":["l"],"model_ids":["m"]}]',
 '["record","p","log_data","l","1",{"events":[1,2,3]}]',
 '["record","p","model","m","1",{"id":"m","name":"Model"}]',
 '["marker",{"project_id":"p","source_version":7,"source_sha":"a","checksum":"b"}]',
 '["ledger",{"version":1,"name":"baseline_v1","checksum":"c","applied_at":"2026-01-01T00:00:00Z"}]',
 '["sequence","63","0",true]',
 '["sequence_definition","20","1","1","9223372036854775807","1","1",false]'
];
const save=(name,lines)=>{const p=path.join(out,name+'.jsonl');fs.writeFileSync(p,lines.join('\n')+'\n',{flag:'wx'});return p;};
async function main(){
 const before=save('before',baseline),same=save('same',baseline.slice().reverse());
 assert.equal((await oracle.run({mode:'equal',before,after:same})).status,'WHOLE_TYPED_CAPTURE_EQUAL');checks++;
 const changes=[
  [0,s=>s.replace('9007199254740993','9007199254740992')],
  [0,s=>s.replace('Ж','Other')], [1,s=>s.replace('𐍈','X')],
  [3,s=>s.replace('[1,2,3]','[1,2,4]')], [4,s=>s.replace('Model','Changed')],
  [5,s=>s.replace('"source_sha":"a"','"source_sha":"z"')],
  [5,s=>s.replace('"checksum":"b"','"checksum":"z"')],
  [6,s=>s.replace('2026-01-01','2026-01-02')],
  [7,s=>s.replace('"0"','"1"')],
  [8,s=>s.replace('9223372036854775807','9223372036854775806')]
 ];
 for(let i=0;i<changes.length;i++){
  const [index,mutate]=changes[i], rows=baseline.slice();rows[index]=mutate(rows[index]);
  await assert.rejects(()=>oracle.run({mode:'equal',before,after:save('mutation-'+i,rows)}));checks++;
 }
 for(const [label,rows] of [['missing',baseline.filter((_,i)=>i!==3)],['extra',[...baseline,'["record","p","log_source","unexpected","1",null]']],['duplicate',[...baseline,baseline[0]]]]){
  await assert.rejects(()=>oracle.run({mode:'equal',before,after:save(label,rows)}));checks++;
 }
 const noSequence=save('no-sequence',baseline.filter(s=>!s.startsWith('["sequence"')));
 await assert.rejects(()=>oracle.run({mode:'equal',before:noSequence,after:same}));checks++;
 const repo=oracle.parseExact('{"logs":{},"current":null,"sequence":0,"user_views":{},"models":{"m":{"id":"m","name":"Model"}},"durable_jobs":{}}');
 const projected=new Map(),counts=oracle.projectExpectations('p',repo,'7',projected);
 assert.deepEqual(counts,{logs:0,models:1,records:1});assert.equal(projected.size,2);checks++;
 repo.models.m.id='other';assert.throws(()=>oracle.projectExpectations('p',repo,'7',new Map()));checks++;
 const args=oracle.argumentsOf(['--mode','partial','--checksum','a']);assert.equal(args.mode,'partial');checks++;
 assert.throws(()=>oracle.argumentsOf(['--mode','equal','--mode','forward']));checks++;
 console.log(JSON.stringify({status:'BENIGN_HISTORICAL_ORACLE_ANTI_FALSE_PASS_REGRESSIONS_PASSED',checks,limits:['Synthetic small data only; no real historical forward/partial acceptance','No PostgreSQL/cleanup/fault/runtime/physical identity credit']}));
}
main().catch(()=>{console.error('historical_oracle_regression_failed');process.exitCode=1;});
