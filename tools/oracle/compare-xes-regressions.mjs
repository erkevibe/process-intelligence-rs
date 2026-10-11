// Project genuine XLog consumer observations into the existing six-regression API.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {spawnSync} from 'node:child_process';
const [executable,referenceFile,outDir]=process.argv.slice(2);
if(!outDir||fs.existsSync(outDir))throw Error('Usage: ACCEPTED_EXE REAL_XES_RESULTS NEW_OUTPUT');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const ref=JSON.parse(fs.readFileSync(referenceFile,'utf8'));
if(ref.corpus_sha256!==sha(fs.readFileSync('fixtures/oracle/corpus.json')))throw Error('Original corpus mismatch');
if(ref.results.length!==6||ref.results.some(r=>r.status!=='ok'||r.exit_code!==0))throw Error('Incomplete actual six-XES reference');
fs.mkdirSync(outDir,{recursive:true});
const projected={corpus_sha256:ref.corpus_sha256,actual_xes_reference_sha256:sha(fs.readFileSync(referenceFile)),projection:'Actual parser -> unchanged LogParser XLog consumer observations; no XES text adapter',results:ref.results.map(r=>({id:r.id,...r.observed.consumer}))};
const file=path.join(outDir,'actual-consumer-projection.json');fs.writeFileSync(file,JSON.stringify(projected,null,2)+'\n',{flag:'wx'});
const run=spawnSync(process.execPath,['tools/oracle/compare-rust.mjs',executable,file,path.join(outDir,'runtime')],{windowsHide:true,timeout:60000,encoding:'utf8',maxBuffer:16*1024*1024});
fs.writeFileSync(path.join(outDir,'compare.stdout.log'),run.stdout??'');fs.writeFileSync(path.join(outDir,'compare.stderr.log'),run.stderr??'');
fs.writeFileSync(path.join(outDir,'process.json'),JSON.stringify({exit_code:run.status,error:run.error?.code??null,reference_sha256:projected.actual_xes_reference_sha256},null,2)+'\n');
if(run.stdout)console.log(run.stdout.trim());
if(run.error||run.status!==0)throw Error('Accepted runtime regression failed; inspect logs');
