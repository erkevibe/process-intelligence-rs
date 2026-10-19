'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {ownedHttp}=require('../owned-http-client.cjs');
const golden=require('./control-resource-golden.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),step=Number(process.argv[3]),out=cfg.output_directory;
const state=JSON.parse(fs.readFileSync(step===1?cfg.seed_state:path.join(out,`resource-${step-1}.state.json`),'utf8'));
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const put=(name,value)=>fs.writeFileSync(path.join(out,name),JSON.stringify(value,null,2),{flag:'wx'});
function check(ok,code){if(!ok)throw Error(code);}
const records=[];
async function request(route,method='GET',body,status=200){
 const headers={Cookie:state.actors.owner.cookie};if(method==='POST'){headers.Origin='http://127.0.0.1:3096';if(!(body instanceof FormData)){body=new URLSearchParams(body);headers['Content-Type']='application/x-www-form-urlencoded';}}
 const r=await ownedHttp({port:3096,route,method,body,headers}),label=`resource-${step}-http-${records.length+1}`;
 fs.writeFileSync(path.join(out,label+'.body'),r.bytes,{flag:'wx'});records.push({route,method,status:r.status,expected:status,location:r.headers.location||null,body_file:label+'.body',sha256:sha(r.bytes),bytes:r.bytes.length});
 check(r.status===status,'unexpected_http_status');return r;
}
const upload=(file,fields={})=>{const body=new FormData();body.set('file',new Blob([fs.readFileSync(file)]),path.basename(file));for(const[k,v]of Object.entries(fields))body.set(k,v);return body;};
const previewToken=r=>{const m=r.bytes.toString('utf8').match(/name="token"[^>]*value="([a-f0-9-]+)"/);check(m,'preview_token_missing');return m[1];};
async function main(){
 let route,body,status=200,kind,error=null;
 switch(step){
 case 1:route='/csv/preview';body=upload(cfg.csv,{delimiter:'comma'});kind='csv-preview';break;
 case 2:route='/csv/import';body={token:state.csv_token,case_column:'case',activity_column:'activity',timestamp_column:'time',lifecycle_column:'lifecycle',order:'source'};status=303;kind='csv-import';break;
 case 3:route='/xes/preview';body=upload(cfg.xes);kind='xes-preview';break;
 case 4:route='/xes/import';body={token:state.xes_token,consent:'yes'};status=303;kind='xes-import';break;
 case 5:route=`/logs/${state.csv_id}/filter`;body={case_activity:'',min_events:'',max_events:'',retain:'[]',remove:'["C"]'};status=303;kind='filter';break;
 case 6:route=`/logs/${state.csv_id}/calendar`;body={timezone:'',offset_minutes:'300',weekdays:'1,2,3,4,5',start_minute:'540',end_minute:'1080',holidays:''};status=303;kind='calendar';break;
 case 7:route=`/logs/${state.csv_id}/view`;body={threshold:'2'};kind='view';break;
 case 8:route='/models/import';body=upload(cfg.bpmn);status=303;kind='model-create';break;
 case 9:{const model=structuredClone(golden.model);model.nodes[1].label='S12 edited task';model.nodes[1].x=110.5;route=`/models/${state.model_id}`;body={model_json:JSON.stringify(model),revision:'1'};status=303;kind='model-save';break;}
 case 10:route=`/logs/${state.csv_id}/filter`;body={case_activity:'',min_events:'5',max_events:'2',retain:'[]',remove:'[]'};status=422;kind='refusal';error='filter_range';break;
 case 11:route=`/models/${state.model_id}`;body={model_json:JSON.stringify(golden.model),revision:'1'};status=409;kind='refusal';error='model_conflict';break;
 default:throw Error('unknown_resource_step');
 }
 const started=new Date().toISOString(),response=await request(route,'POST',body,status),finished=new Date().toISOString();
 if(error)check(response.bytes.toString('utf8').includes(error),'unexpected_refusal_reason');
 if(kind==='csv-preview')state.csv_token=previewToken(response);
 if(kind==='xes-preview'){
  state.xes_token=previewToken(response);const report=await request(`/xes/previews/${state.xes_token}/report`);
  const json=JSON.parse(report.bytes.toString('utf8'));check(json.policy==='apromore-validateLog-bbf24df-preview-v1'&&json.source_cases===2&&json.source_events===5&&json.changes.length===0,'unexpected_xes_preview');
 }
 if(kind==='csv-import'||kind==='xes-import'){
  check(/^\/logs\/log-[0-9]+$/.test(response.headers.location),'created_log_identity');state[kind==='csv-import'?'csv_id':'xes_id']=response.headers.location.split('/').at(-1);
 }
 if(kind==='view')check(response.bytes.toString('utf8').includes('datastar-patch-elements'),'view_patch_missing');
 if(kind==='model-create'){check(/^\/models\/model-[0-9]+$/.test(response.headers.location),'created_model_identity');state.model_id=response.headers.location.split('/').at(-1);}
 if(kind==='csv-import'||kind==='xes-import'||kind==='filter'||kind==='calendar'){
  const id=kind==='xes-import'?state.xes_id:state.csv_id;await request(`/logs/${id}/export`);
 }
 if(kind==='model-create'||kind==='model-save')await request(`/models/${state.model_id}/json`);
 put(`resource-${step}.intent.json`,{step,kind,status,error,started,finished,route});put(`resource-${step}.state.json`,state);put(`resource-${step}.http-result.json`,{status:'FINITE_HTTP_RESOURCE_STEP_COMPLETED',records});
 process.stdout.write(JSON.stringify({step,kind,status:'HTTP_STEP_COMPLETED'})+'\n');
}
main().catch(error=>{try{put(`resource-${step}.failure.json`,{status:'FAILED_RETAINED',reason:error.message,records});}catch{}process.exitCode=1;});
