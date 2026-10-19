'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),golden=require('./control-resource-golden.cjs');
const [out,number,config]=process.argv.slice(2),step=Number(number),cfg=JSON.parse(fs.readFileSync(config,'utf8'));
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const read=name=>JSON.parse(fs.readFileSync(path.join(out,name),'utf8'));
const rows=name=>fs.readFileSync(path.join(out,name),'utf8').trim().split('\n').map(JSON.parse);
function check(ok,code){if(!ok)throw Error(code);}
const equal=(a,b,code)=>check(canonical(a)===canonical(b),code);
const key=r=>({kv:'1'+r[1],project:'2'+r[1],record:'3'+r[1]+'/'+r[2]+'/'+r[3],marker:'4'+r[1]?.project_id,ledger:'5'+r[1]?.version,sequence:'6',sequence_definition:'7'})[r[0]];
const sortRows=r=>r.sort((a,b)=>key(a)<key(b)?-1:key(a)>key(b)?1:0);
try{
 const pre=rows(`resource-${step}-pre.stdout`),post=rows(`resource-${step}-post.stdout`),intent=read(`resource-${step}.intent.json`),state=read(`resource-${step}.state.json`);
 const expected=structuredClone(pre),auth=expected.find(r=>r[0]==='kv'&&r[1]==='auth')?.[3];check(auth,'auth_missing');
 const session=auth.sessions[sha(state.actors.owner.cookie.split('=')[1])];check(session,'session_missing');
 const project=session.project_id,actor=session.user_id;check(auth.projects[project]?.members[actor]==='owner','actor_scope_not_owner');
 const row=expected.find(r=>r[0]==='project'&&r[1]===project),actual=post.find(r=>r[0]==='project'&&r[1]===project);check(row&&actual,'header_missing');
 const header=row[3],revision=Number(row[2]);let action,rule,resources=[],parameters=null;
 function record(kind,id){return expected.find(r=>r[0]==='record'&&r[1]===project&&r[2]===kind&&r[3]===id);}
 function observedRecord(kind,id){return post.find(r=>r[0]==='record'&&r[1]===project&&r[2]===kind&&r[3]===id)?.[5];}
 function put(kind,id,document){const old=record(kind,id);if(old){old[4]=String(Number(old[4])+1);old[5]=document;}else expected.push(['record',project,kind,id,'1',document]);}
 function allocate(){
  const seq=expected.find(r=>r[0]==='sequence');check(seq,'sequence_missing');
  const value=Number(seq[1])+(seq[3]?1:0),logged=Number(seq[2]);check(Number.isSafeInteger(value)&&value>0&&logged>=0&&logged<=32,'allocator_pre_invalid');
  seq[1]=String(value);seq[2]=String(!seq[3]||logged===0?32:logged-1);seq[3]=true;return value;
 }
 const baseParameters=()=>({action,expected_repository_revision:revision,resources,validated_action_parameters:null,logs:[],organization:null,jobs:{},models:[],actor_current:null,actor_views:null});
 const inWindow=(at,code)=>{const n=Date.parse(at);check(Number.isFinite(n)&&n>=Date.parse(intent.started)&&n<=Date.parse(intent.finished),code);};
 function logParameters(id,source=null){
  const l=record('log_state',id)?.[5];check(l,'affected_log_state_missing');
  return{id,source_sha256:l.source_sha256,order:l.order,filters:l.filters,calendar:l.calendar,threshold:l.threshold,selected:l.selected,selected_case:l.selected_case,preview:source?{operation_id:state.xes_token,policy:'apromore-validateLog-bbf24df-preview-v1',actions:0}:null};
 }
 if(['csv-preview','xes-preview','refusal'].includes(intent.kind)){
  equal(pre,post,'readonly_or_refused_resource_changed_database');
 }else if(['csv-import','xes-import'].includes(intent.kind)){
  const xes=intent.kind==='xes-import',number=allocate(),id=xes?state.xes_id:state.csv_id;
  check(id===`log-${number}`&&!record('log_state',id),'allocated_log_identity');
  const observed=observedRecord('log_state',id);check(observed,'imported_state_missing');inWindow(observed.created_at,'created_at_outside_import');
  check(Number.isInteger(observed.elapsed_ms)&&observed.elapsed_ms>=0&&observed.elapsed_ms<=Date.parse(intent.finished)-Date.parse(intent.started)+1000,'elapsed_ms_bound');
  const data=structuredClone(xes?golden.xesData:golden.csvData),sourceFile=xes?cfg.xes:cfg.csv,source=fs.readFileSync(sourceFile),digest=sha(source);
  const log={id,filename:path.basename(sourceFile),created_at:observed.created_at,analysis_version:number,view_revision:0,threshold:1,selected:null,selected_case:null,elapsed_ms:observed.elapsed_ms,source_sha256:digest,order:'source',filters:structuredClone(golden.filters),calendar:structuredClone(golden.calendar),project_id:project};
  let sourceDocument=data;
  if(xes){
   check(/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(state.xes_token),'preview_identity');
   const at=observedRecord('log_source',id)?.provenance?.confirmed_at;inWindow(at,'provenance_time_outside_confirmation');
   sourceDocument={source_envelope_version:1,source:data,provenance:{schema_version:1,operation_id:state.xes_token,actor_id:actor,origin_project_id:project,confirmed_at:at,policy:'apromore-validateLog-bbf24df-preview-v1',original_utf8:source.toString('utf8'),source_sha256:digest,source_cases:2,source_events:5,actions:[]}};
  }
  put('log_state',id,log);put('log_data',id,data);put('log_source',id,sourceDocument);put('log_analysis',id,structuredClone(golden.analysis));
  header.sequence++;header.log_ids.push(id);header.log_ids.sort();header.current[actor]=id;
  action=xes?'xes_import_confirmed':'log_imported';rule=xes?'service_preview_confirm_v1':'strict_import_v1';
  resources=['log_analysis','log_data','log_source','log_state'].map(kind=>`${kind}/${id}`).sort();parameters=baseParameters();parameters.logs=[logParameters(id,xes)];
  if(!xes)parameters.validated_action_parameters={format:'csv',mapping:{case_column:'case',activity_column:'activity',timestamp_column:'time',lifecycle_column:'lifecycle',delimiter:44,order:'source'}};
 }else if(intent.kind==='filter'){
  const id=state.csv_id,log=structuredClone(record('log_state',id)[5]);log.filters={...structuredClone(golden.filters),remove_activities:['C']};log.analysis_version=allocate();log.selected=null;log.selected_case=null;log.view_revision=0;
  put('log_state',id,log);put('log_data',id,structuredClone(golden.filteredData));put('log_analysis',id,structuredClone(golden.filteredAnalysis));
  for(const views of Object.values(header.user_views))delete views[id];
  action='filter_applied';rule='source_case_then_activity_projection_v1';resources=[id,`log_state/${id}`,`log_data/${id}`,`log_analysis/${id}`].sort();parameters=baseParameters();parameters.logs=[logParameters(id)];
 }else if(intent.kind==='calendar'){
  const id=state.csv_id,log=structuredClone(record('log_state',id)[5]);log.calendar={...structuredClone(golden.calendar),offset_minutes:300};put('log_state',id,log);
  action='calendar_changed';rule='half_open_business_calendar_v1';resources=[id,`log_state/${id}`].sort();parameters=baseParameters();parameters.logs=[logParameters(id)];
 }else if(intent.kind==='view'){
  const id=state.csv_id,old=header.user_views[actor]?.[id];header.user_views[actor]??={};header.user_views[actor][id]={threshold:2,selected:null,selected_case:null,revision:(old?.revision||0)+1};
  action='view_changed';rule='actor_private_view_v1';parameters=baseParameters();parameters.actor_current=header.current[actor]??null;parameters.actor_views=header.user_views[actor];
 }else if(intent.kind==='model-create'||intent.kind==='model-save'){
  const creating=intent.kind==='model-create',id=state.model_id,model=structuredClone(golden.model);
  if(creating){check(id===`model-${allocate()}`&&!record('model',id),'allocated_model_identity');header.sequence++;header.model_ids.push(id);header.model_ids.sort();}
  else{model.nodes[1].label='S12 edited task';model.nodes[1].x=110.5;}
  const modelRevision=creating?1:record('model',id)[5].revision+1,name=path.basename(cfg.bpmn);
  put('model',id,{id,name,revision:modelRevision,model,source_log:null});
  action=creating?'model_created':'model_saved';rule='validated_model_project_cas_v1';resources=[id,`model/${id}`].sort();parameters=baseParameters();parameters.models=[{id,revision:modelRevision,name,source_log:null,model_sha256:sha(golden.rustModelJson(model))}];
 }else throw Error('unknown_resource_oracle_kind');
 if(action){
  const audit=header.audit||{total:0,entries:[]},total=audit.total+1,actualEntry=actual[3].audit?.entries?.at(-1);check(actualEntry,'audit_missing');inWindow(actualEntry.at,'audit_time_outside_request');
  const entry={sequence:total,at:actualEntry.at,actor,project,action,resources,revision:revision+1,policy:{version:1,rule,parameters_sha256:sha(canonical(parameters))},outcome:'committed'};
  equal(actualEntry,entry,'resource_audit_policy_or_identity');header.audit={total,entries:[...audit.entries,entry].slice(-512)};row[2]=String(revision+1);
  equal(sortRows(expected),sortRows(post),'unexpected_full_resource_database_delta');
 }
 const http=read(`resource-${step}.http-result.json`);
 for(const request of http.records){
  const log=request.route.match(/^\/logs\/(log-[0-9]+)\/export$/),model=request.route.match(/^\/models\/(model-[0-9]+)\/json$/);
  if(model)equal(JSON.parse(fs.readFileSync(path.join(out,request.body_file),'utf8')),record('model',model[1])[5],'model_json_export_differs');
  if(log){
   const id=log[1],l=record('log_state',id)[5],a=record('log_analysis',id)[5],data=record('log_data',id)[5],source=record('log_source',id)[5],p=source.provenance;
   const history=p?{schema_version:1,policy:p.policy,operation_id:p.operation_id,actor_id:p.actor_id,origin_project_id:p.origin_project_id,confirmed_at:p.confirmed_at,source_cases:p.source_cases,source_events:p.source_events,actions:p.actions,source_sha256:p.source_sha256}:null;
   const exported={schema_version:1,log_id:id,name:l.filename,analysis_version:l.analysis_version,view_revision:l.view_revision,
    parameters:{min_edge_frequency:l.threshold,order:l.order,lifecycle:'each-event',filters:l.filters,calendar:l.calendar},source_sha256:l.source_sha256,project_id:project,import_history:history,
    business_durations:data.cases.map(c=>({case_id:c.id,status:'computed',start:'2026-10-12T04:00:00Z',end:'2026-10-12T05:00:00Z',business_millis:l.calendar.offset_minutes===300?3600000:0})),
    analysis:a,view:{log_id:id,analysis_version:l.analysis_version,view_revision:l.view_revision,min_edge_frequency:l.threshold,max_edge_frequency:a.max_edge_frequency,nodes:a.nodes,edges:a.edges.filter(e=>e.count>=l.threshold),selected_id:null,selected_case_id:null,case_highlight:{node_ids:[],edge_ids:[]}},
    warnings:data.warnings,elapsed_ms:l.elapsed_ms,selected_case:null,compatibility:{apromore:'unverified'},created_at:l.created_at};
   equal(JSON.parse(fs.readFileSync(path.join(out,request.body_file),'utf8')),exported,'full_log_export_differs');
  }
 }
 fs.writeFileSync(path.join(out,`resource-${step}.expected-parameters.json`),canonical(parameters),{flag:'wx'});fs.writeFileSync(path.join(out,`resource-${step}.expected-full-state.json`),canonical(expected),{flag:'wx'});
 process.stdout.write(JSON.stringify({status:'RESOURCE_FULL_PRE_DERIVED_STATE_VERIFIED',step,kind:intent.kind,action:action||null,all_rows_compared:true})+'\n');
}catch(error){process.stderr.write(error.message+'\n');process.exitCode=1;}
