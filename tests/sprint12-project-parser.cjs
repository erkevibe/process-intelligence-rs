'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {namedProjectOpenId}=require('../tools/sprint12/named-project-row.cjs');
const [input,out]=process.argv.slice(2),bytes=fs.readFileSync(input),html=bytes.toString('utf8');
const old=[...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/g)].map(m=>m[1]).filter(row=>row.includes('S12 project'));
if(old.length!==3)throw Error('actual_failed_old_selector_not_reproduced');
const id=namedProjectOpenId(html,'S12 project');
if(!/^project-[a-f0-9]{32}$/.test(id))throw Error('actual_open_identity_missing');
let rejected=0;
for(const candidate of ['',html.replaceAll('S12 project','Other project'),html+old[0].replace(/^/,'<tr>').replace(/$/,'</tr>')]){
 try{namedProjectOpenId(candidate,'S12 project');}catch{rejected++;}
}
if(rejected!==3)throw Error('empty_missing_or_duplicate_selector_not_refused');
const result={status:'PASS',actual_failed_body_sha256:crypto.createHash('sha256').update(bytes).digest('hex'),old_candidates:3,new_candidates:1,negative_cases:3,selector_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.resolve('tools/sprint12/named-project-row.cjs'))).digest('hex')};
fs.writeFileSync(path.join(out,'result.json'),JSON.stringify(result,null,2),{flag:'wx'});process.stdout.write(JSON.stringify(result)+'\n');
