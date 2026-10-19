'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {ownedHttp}=require('../owned-http-client.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),out=cfg.output_directory;
const state=JSON.parse(fs.readFileSync(cfg.seed_state,'utf8'));
const pre=fs.readFileSync(path.join(out,'cas-pre.stdout'),'utf8').trim().split('\n').map(JSON.parse);
const auth=pre.find(r=>r[0]==='kv'&&r[1]==='auth')[3],cookie=state.actors.owner.cookie;
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const binding=auth.sessions[sha(cookie.split('=')[1])],project=binding.project_id,revision=auth.projects[project].revision||1;
const records=[];const put=(n,v)=>fs.writeFileSync(path.join(out,n),JSON.stringify(v,null,2),{flag:'wx'});
async function request(index,name){
 const started=new Date().toISOString();
 const r=await ownedHttp({port:3096,route:`/projects/${project}/rename`,method:'POST',
  headers:{Cookie:cookie,Origin:'http://127.0.0.1:3096','Content-Type':'application/x-www-form-urlencoded'},
  body:new URLSearchParams({name,revision:String(revision)})});
 const finished=new Date().toISOString(),body_file=`cas-${index}.body`;
 fs.writeFileSync(path.join(out,body_file),r.bytes,{flag:'wx'});
 const record={index,name,revision,project,status:r.status,started,finished,body_file,sha256:sha(r.bytes),bytes:r.bytes.length,request_id:r.headers['x-request-id']||null};records.push(record);
 if(r.status!==303&&!(r.status===409&&r.bytes.toString('utf8').includes('project_conflict')))throw Error('cas_specific_response');
 return record;
}
async function main(){
 const results=await Promise.all([request(1,'S12 concurrent rename A'),request(2,'S12 concurrent rename B')]);
 if(results.filter(r=>r.status===303).length!==1||results.filter(r=>r.status===409).length!==1)throw Error('cas_one_winner_required');
 if(Math.max(...results.map(r=>Date.parse(r.started)))>Math.min(...results.map(r=>Date.parse(r.finished))))throw Error('cas_http_intervals_did_not_overlap');
 if(results.some(r=>!r.request_id)||results[0].request_id===results[1].request_id)throw Error('cas_request_identity');
 put('cas-http-result.json',{status:'STOCK_OVERLAPPING_HTTP_CAS_RESPONSES',records:results,actor:binding.user_id,project,
  limits:['Overlapping client HTTP intervals; no held final Auth instruction or uncertain acknowledgement proof']});
 process.stdout.write('STOCK_OVERLAPPING_HTTP_CAS_RESPONSES\n');
}
main().catch(e=>{put('cas-failure.json',{status:'FAILED_RETAINED',reason:e.message,records});process.exitCode=1;});
