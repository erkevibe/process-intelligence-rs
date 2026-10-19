'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {ownedHttp}=require('../owned-http-client.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const state=JSON.parse(fs.readFileSync(path.join(cfg.output_directory,'http-private-state.json'),'utf8'));
async function main(){
 const bytes=fs.readFileSync(cfg.bpmn),body=new FormData();body.set('file',new Blob([bytes]),'linear.bpmn');
 const r=await ownedHttp({port:3096,route:'/models/import',method:'POST',body,headers:{Cookie:state.actors.owner.cookie,Origin:'http://127.0.0.1:3096'}});
 fs.writeFileSync(path.join(cfg.output_directory,'model-seed.body'),r.bytes,{flag:'wx'});
 if(r.status!==303||!/^\/models\/model-[0-9]+$/.test(r.headers.location))throw Error('ui_model_seed_refused');
 state.model_id=r.headers.location.split('/').at(-1);
 fs.writeFileSync(path.join(cfg.output_directory,'ui-fixture-state.json'),JSON.stringify(state,null,2),{flag:'wx'});
 process.stdout.write(JSON.stringify({status:'PUBLIC_MODEL_API_FIXTURE_SEEDED',source_sha256:crypto.createHash('sha256').update(bytes).digest('hex'),model_id:state.model_id,limits:['API fixture setup only; no browser upload or new producer acceptance']})+'\n');
}
main().catch(e=>{process.stderr.write(e.message+'\n');process.exitCode=1;});
