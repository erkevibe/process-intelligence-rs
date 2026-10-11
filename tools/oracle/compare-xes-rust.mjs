// Differences are observations. Only explicit manual Rust contracts determine pass.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {spawnSync} from 'node:child_process';
const [executable,corpusDir,referenceFile,outDir]=process.argv.slice(2);
if(!outDir||fs.existsSync(outDir))throw Error('Usage: OBSERVER_EXE CORPUS REFERENCE_JSON NEW_OUTPUT');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const corpusBytes=fs.readFileSync(path.join(corpusDir,'corpus.json'));const corpus=JSON.parse(corpusBytes);const ref=JSON.parse(fs.readFileSync(referenceFile,'utf8'));
if(ref.corpus_sha256!==sha(corpusBytes))throw Error('Reference corpus mismatch');
fs.mkdirSync(outDir,{recursive:true});
const results=[];
for(const f of corpus.fixtures){
 const fixture=path.resolve(corpusDir,f.id+'.xes');if(sha(fs.readFileSync(fixture))!==f.sha256)throw Error('Fixture mismatch');
 const legacy=ref.results.find(x=>x.id===f.id);if(!legacy)throw Error('Missing reference result');
 const modes={};
 for(const order of ['source','timestamp']){
  const run=spawnSync(path.resolve(executable),[fixture,order],{windowsHide:true,timeout:20000,encoding:'utf8',maxBuffer:16*1024*1024});
  fs.writeFileSync(path.join(outDir,f.id+'.'+order+'.stdout.log'),run.stdout??'');fs.writeFileSync(path.join(outDir,f.id+'.'+order+'.stderr.log'),run.stderr??'');
  if(run.error||run.status!==0)throw Error('Rust observer process failure');
  modes[order]=JSON.parse(run.stdout);
 }
 const expectedError=f.rust_error??null;
 const sourceOk=expectedError?modes.source.status==='rejected'&&modes.source.error.code===expectedError:modes.source.status==='ok'&&JSON.stringify(modes.source.log.cases[0].events.map(x=>x.activity))===JSON.stringify(f.source_sequence);
 const timestampExpectedError=expectedError??f.timestamp_error??(f.events.some(x=>!x.timestamp)?'missing_timestamp':null);
 const timeSequence=f.timestamp_sequence??f.source_sequence;
 const timestampOk=timestampExpectedError?modes.timestamp.status==='rejected'&&modes.timestamp.error.code===timestampExpectedError:modes.timestamp.status==='ok'&&JSON.stringify(modes.timestamp.log.cases[0].events.map(x=>x.activity))===JSON.stringify(timeSequence);
 const differences=[];
 const legacyChecks={};
 if(modes.source.status!==legacy.status)differences.push({field:'acceptance',rust:modes.source.status,legacy:legacy.status});
 if(modes.source.status==='ok'&&legacy.status==='ok'){
  legacyChecks.log_name=modes.source.log.name===legacy.observed.name;
  legacyChecks.case_count=modes.source.log.cases.length===legacy.observed.cases.length;
  if(!legacyChecks.log_name)differences.push({field:'name',rust:modes.source.log.name,legacy:legacy.observed.name});
  if(!legacyChecks.case_count)differences.push({field:'cases.length',rust:modes.source.log.cases.length,legacy:legacy.observed.cases.length});
  for(let c=0;c<modes.source.log.cases.length;c++){
   const rc=modes.source.log.cases[c],lc=legacy.observed.cases[c];
   if(!lc){differences.push({field:`cases[${c}]`,reason:'missing legacy case'});continue;}
   if(rc.name!==lc.name)differences.push({field:`cases[${c}].name`,rust:rc.name,legacy:lc.name});
   if(rc.events.length!==lc.events.length)differences.push({field:`cases[${c}].events.length`,rust:rc.events.length,legacy:lc.events.length});
   for(let i=0;i<rc.events.length;i++){
    const re=rc.events[i],le=lc.events[i];
    if(!le){differences.push({field:`cases[${c}].events[${i}]`,reason:'missing legacy event'});continue;}
    for(const key of ['activity','lifecycle'])if(re[key]!==le[key])differences.push({field:`cases[${c}].events[${i}].${key}`,rust:re[key],legacy:le[key]});
    const rm=re.timestamp?Date.parse(re.timestamp):null;
    if(rm!==le.timestamp_millis)differences.push({field:`cases[${c}].events[${i}].timestamp_millis`,rust:rm,legacy:le.timestamp_millis});
    if(re.timestamp&&/\.\d{4,}/.test(re.timestamp))differences.push({field:`cases[${c}].events[${i}].timestamp_precision`,rust:re.timestamp,legacy_millis:le.timestamp_millis,reason:'Rust retains submillisecond precision; java.util.Date observation is milliseconds'});
   }
  }
 }
 if(legacy.status==='ok'){
  const lc=legacy.observed.consumer;
  const events=legacy.observed.cases.flatMap(c=>c.events);
  const variants=new Map();
  for(const c of legacy.observed.cases){const k=JSON.stringify(c.events.map(e=>e.activity));variants.set(k,(variants.get(k)??0)+1);}
  const sort=v=>JSON.stringify(v.map(x=>[x.sequence,x.count]).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b))));
  legacyChecks.consumer_cases=lc.cases===legacy.observed.cases.length;
  legacyChecks.consumer_events=lc.events===events.length;
  legacyChecks.consumer_activities=lc.activities===new Set(events.map(e=>e.activity)).size;
  legacyChecks.consumer_variants=sort(lc.variants)===sort([...variants].map(([sequence,count])=>({sequence:JSON.parse(sequence),count})));
  for(const [field,pass]of Object.entries(legacyChecks))if(field.startsWith('consumer_')&&!pass)differences.push({field,reason:'consumer differs from genuine parser observation'});
 }
 const manualCardinalityOk=expectedError?true:modes.source.status==='ok'&&modes.source.log.name===f.id&&modes.source.log.cases.length===1&&modes.source.log.cases[0].name==='case-1'&&modes.source.log.cases[0].events.length===f.events.length;
 const attributeOk=expectedError?true:manualCardinalityOk&&modes.source.log.cases[0].events.every((e,i)=>e.ordinal===i&&e.lifecycle===f.events[i].lifecycle&&(e.timestamp?Date.parse(e.timestamp):null)===(f.events[i].timestamp?Date.parse(f.events[i].timestamp):null));
 const precisionOk=f.rust_timestamp?modes.source.status==='ok'&&modes.source.log.cases[0].events[0].timestamp===f.rust_timestamp:true;
 results.push({id:f.id,input_sha256:f.sha256,rust:modes,legacy_status:legacy.status,legacy_observed:legacy.observed,legacy_checks:legacyChecks,manual_checks:{source_order_or_error:sourceOk,timestamp_order_or_error:timestampOk,cardinality_names:manualCardinalityOk,attributes:attributeOk,exact_precision:precisionOk},differences});
}
const manualPassed=results.every(x=>Object.values(x.manual_checks).every(Boolean));
const consumerPassed=results.every(x=>Object.entries(x.legacy_checks).filter(([k])=>k.startsWith('consumer_')).every(([,v])=>v));
const report={schema_version:1,created_at:new Date().toISOString(),observer_executable_sha256:sha(fs.readFileSync(executable)),corpus_sha256:sha(corpusBytes),reference_sha256:sha(fs.readFileSync(referenceFile)),scope:'parser attribute observations and actual LogParser XLog consumer; manager validateLog/Portal/calendar/miner excluded',manual_contract_passed:manualPassed,legacy_consumer_consistency_passed:consumerPassed,passed:manualPassed&&consumerPassed,results};
fs.writeFileSync(path.join(outDir,'comparison.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({passed:report.passed,examples:results.length,differences:results.filter(x=>x.differences.length).map(x=>({id:x.id,fields:x.differences.map(d=>d.field)})),report:path.resolve(outDir,'comparison.json')}));
if(!report.passed)process.exitCode=1;
