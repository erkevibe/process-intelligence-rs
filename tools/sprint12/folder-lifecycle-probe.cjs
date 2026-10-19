'use strict';
// One real HTTP mutation per invocation. All bodies/cookies stay in private fixtures.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {ownedHttp}=require('../owned-http-client.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),step=Number(process.argv[3]);
const out=cfg.output_directory;
const put=(name,value)=>fs.writeFileSync(path.join(out,name),JSON.stringify(value,null,2),{flag:'wx'});
const read=name=>JSON.parse(fs.readFileSync(name,'utf8'));
const state=step===1?read(cfg.seed_state):read(path.join(out,`step-${step-1}.state.json`));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function check(ok,code){if(!ok)throw Error(code);}
const records=[];
async function request(actor,route,method='GET',values,status=200){
 const headers={Cookie:state.actors[actor].cookie};
 let body;
 if(method==='POST'){headers.Origin='http://127.0.0.1:3096';headers['Content-Type']='application/x-www-form-urlencoded';body=new URLSearchParams(values);}
 const r=await ownedHttp({port:3096,route,method,body,headers});
 const label=`step-${step}-${process.argv[4]==='pre'?'pre-read':'http'}-${records.length+1}`;
 fs.writeFileSync(path.join(out,label+'.body'),r.bytes,{flag:'wx'});
 records.push({route,method,status:r.status,expected:status,body_file:label+'.body',sha256:sha(r.bytes),bytes:r.bytes.length});
 check(r.status===status,'unexpected_http_status');
 return r.bytes;
}
async function main(){
 if(process.argv[4]==='pre'){
  put(`step-${step}.pre-folders.json`,JSON.parse((await request('owner','/folders/json')).toString('utf8')));
  process.stdout.write(JSON.stringify({step,status:'READ_ONLY_PRE_CAPTURED'})+'\n');return;
 }
 const pre=read(path.join(out,`step-${step}.pre-folders.json`));
 const rev=pre.revision,A=state.folderA,B=state.folderB;
 let actor='owner',route,values={revision:String(rev)},status=303,action,resource,edit,error;
 switch(step){
 case 1:route='/folders';values.name='S12 A';action='folder_created';edit={kind:'create',name:'S12 A',parent:null,key:'folderA'};break;
 case 2:route='/folders';values.name='S12 B';action='folder_created';edit={kind:'create',name:'S12 B',parent:null,key:'folderB'};break;
 case 3:route=`/folders/${B}/rename`;values.name='S12 B renamed';action='folder_renamed';resource=B;edit={kind:'rename',id:B,name:values.name};break;
 case 4:route=`/folders/${B}/move`;values.parent=A;action='folder_moved';resource=B;edit={kind:'move',id:B,parent:A};break;
 case 5:route='/folders/assign';values.resource=state.logs.csv;values.folder=B;action='resource_moved';resource=values.resource;edit={kind:'assign',resource,folder:B};break;
 case 6:route=`/folders/${A}/move`;values.parent=B;status=422;error='folder_cycle';break;
 case 7:route=`/folders/${A}/delete`;status=422;error='folder_not_empty';break;
 case 8:route='/folders';values.name='S12 A';status=422;error='folder_duplicate';break;
 case 9:route='/folders';values.name='Missing parent';values.parent='folder-00000000-0000-4000-8000-000000000001';status=422;error='folder_parent';break;
 case 10:route='/folders/assign';values.resource='log-not-in-project';values.folder=B;status=422;error='folder_resource';break;
 case 11:route=`/folders/${B}/rename`;values.name='Stale';values.revision=String(rev-1);status=409;error='storage_conflict';break;
 case 12:actor='viewer';route=`/folders/${B}/rename`;values.name='Viewer forbidden';status=403;error='access_denied';break;
 case 13:actor='editor';route=`/folders/${B}/rename`;values.name='S12 editor rename';action='folder_renamed';resource=B;edit={kind:'rename',id:B,name:values.name};break;
 case 14:actor='foreign';route=`/folders/${B}/rename`;values.name='Foreign forbidden';values.revision=String(JSON.parse((await request('foreign','/folders/json')).toString('utf8')).revision);status=422;error='folder_missing';break;
 case 15:actor='foreign';route='/folders/assign';values.resource=state.logs.csv;values.folder=B;values.revision=String(JSON.parse((await request('foreign','/folders/json')).toString('utf8')).revision);status=422;error='folder_resource';break;
 case 16:route='/folders/assign';values.resource=state.logs.csv;values.folder='';action='resource_moved';resource=values.resource;edit={kind:'assign',resource,folder:null};break;
 case 17:route=`/folders/${B}/delete`;action='folder_deleted';resource=B;edit={kind:'delete',id:B};break;
 case 18:route=`/folders/${A}/delete`;action='folder_deleted';resource=A;edit={kind:'delete',id:A};break;
 default:throw Error('unknown_step');
 }
 const started=new Date().toISOString();
 const response=await request(actor,route,'POST',values,status);
 if(error)check(response.toString('utf8').includes(error),'unexpected_refusal_reason');
 const finished=new Date().toISOString();
 const post=JSON.parse((await request('owner','/folders/json')).toString('utf8'));
 if(edit?.kind==='create'){
  const created=Object.keys(post.organization.folders).filter(id=>!Object.hasOwn(pre.organization.folders,id));
  check(created.length===1&&/^folder-[a-f0-9-]{36}$/.test(created[0]),'created_folder_identity');
  resource=created[0];edit.id=resource;state[edit.key]=resource;
 }
 put(`step-${step}.post-folders.json`,post);
 put(`step-${step}.state.json`,state);
 put(`step-${step}.http-result.json`,{step,actor,action:action||null,resource:resource||null,edit:edit||null,status,error:error||null,started,finished,records});
 process.stdout.write(JSON.stringify({step,status:'HTTP_STEP_COMPLETED',mutation_expected:status===303})+'\n');
}
main().catch(error=>{try{put(`step-${step}.http-failure.json`,{status:'FAILED_RETAINED',reason:error.message,records});}catch{}process.exitCode=1;});
