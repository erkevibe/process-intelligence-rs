'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {isDeepStrictEqual}=require('node:util');
const {ownedHttp}=require('../owned-http-client.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),round=process.argv[3];
if(!['baseline','restart','recovery'].includes(round))throw Error('recovery_round');
const state=JSON.parse(fs.readFileSync(cfg.seed_state,'utf8'));
const records=[];
function put(name,value){fs.writeFileSync(path.join(cfg.output_directory,name),value,{flag:'wx'});}
async function main(){
 const routes=[['audit','/audit/export'],['csv',`/logs/${state.csv_id}/export`],['xes',`/logs/${state.xes_id}/export`],['model',`/models/${state.model_id}/json`]];
 for(const [name,route]of routes){
  const r=await ownedHttp({port:3096,route,method:'GET',headers:{Cookie:state.actors.owner.cookie}});
  if(r.status!==200)throw Error('recovery_export_status_'+name);
  const json=JSON.parse(r.bytes.toString('utf8'));
  if(round!=='baseline'){
   const previous=JSON.parse(fs.readFileSync(path.join(cfg.output_directory,'baseline-'+name+'.json'),'utf8'));
   if(!isDeepStrictEqual(json,previous))throw Error('recovery_export_mismatch_'+name);
  }else if(name==='audit'){
   const accepted=JSON.parse(fs.readFileSync(cfg.audit_export,'utf8'));
   if(!isDeepStrictEqual(json,accepted))throw Error('accepted_retention_export_mismatch');
  }
  put(round+'-'+name+'.json',r.bytes);
  records.push({name,route,status:r.status,bytes:r.bytes.length,sha256:crypto.createHash('sha256').update(r.bytes).digest('hex')});
 }
 put(round+'-http-result.json',JSON.stringify({status:'MIXED_READ_ONLY_EXPORTS_EQUAL',round,records,login_performed:false},null,2));
 process.stdout.write(JSON.stringify({status:'MIXED_READ_ONLY_EXPORTS_EQUAL',round,exports:records.length})+'\n');
}
main().catch(e=>{put(round+'-failure.json',JSON.stringify({status:'FAILED_RETAINED',reason:e.message,records}));process.exitCode=1;});
