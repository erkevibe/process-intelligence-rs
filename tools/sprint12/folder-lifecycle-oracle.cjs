'use strict';
// Expected full state is derived from PRE + requested edit + generated folder ID.
// Only the bounded server timestamp is observed from the audit entry.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const [out,stepString]=process.argv.slice(2),step=Number(stepString);
const read=name=>JSON.parse(fs.readFileSync(path.join(out,name),'utf8'));
function check(ok,code){if(!ok)throw Error(code);}
const canonical=v=>JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0)):x);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const rows=name=>fs.readFileSync(path.join(out,name),'utf8').trimEnd().split('\n').map(line=>JSON.parse(line));
const equal=(a,b,code)=>check(canonical(a)===canonical(b),code);
try{
 const pre=rows(`step-${step}-pre.stdout`),post=rows(`step-${step}-post.stdout`);
 const http=read(`step-${step}.http-result.json`),before=read(`step-${step}.pre-folders.json`),after=read(`step-${step}.post-folders.json`);
 const state=read(`step-${step}.state.json`),expected=structuredClone(pre);
 if(http.status!==303){equal(pre,post,'refusal_changed_full_database');equal(before,after,'refusal_changed_folder_response');}
 else{
  const row=expected.find(r=>r[0]==='project'&&r[1]===state.project);
  const actual=post.find(r=>r[0]==='project'&&r[1]===state.project);
  check(row&&actual,'project_header_missing');
  check(Number(row[2])===before.revision,'pre_revision_disagrees');
  const auth=pre.find(r=>r[0]==='kv'&&r[1]==='auth')?.[3];check(auth,'pre_auth_missing');
  const token=state.actors[http.actor].cookie.split('=')[1];
  const session=auth.sessions[sha(token)];check(session&&session.project_id===state.project,'pre_session_binding');
  const role=auth.projects[state.project]?.members[session.user_id];
  check(role==='owner'||role==='editor','pre_actor_not_writer');
  equal(before.resources,[...new Set([...row[3].log_ids,...row[3].model_ids])].sort(),'pre_api_database_resource_catalog_disagrees');
  const organization=structuredClone(row[3].organization||{folders:{},assignments:{}}),edit=http.edit;
  equal(before.organization,organization,'pre_api_database_organization_disagrees');
  if(edit.kind==='create')organization.folders[edit.id]={name:edit.name,parent:edit.parent};
  else if(edit.kind==='rename')organization.folders[edit.id].name=edit.name;
  else if(edit.kind==='move')organization.folders[edit.id].parent=edit.parent;
  else if(edit.kind==='delete')delete organization.folders[edit.id];
  else if(edit.kind==='assign'){if(edit.folder===null)delete organization.assignments[edit.resource];else organization.assignments[edit.resource]=edit.folder;}
  else throw Error('unknown_expected_edit');
  equal(after,{revision:before.revision+1,organization,resources:before.resources},'unexpected_folder_result');
  const parameters={action:http.action,expected_repository_revision:before.revision,resources:[http.resource],validated_action_parameters:null,logs:[],organization,jobs:{},models:[],actor_current:null,actor_views:null};
  const total=(row[3].audit?.total||0)+1;
  const entry=actual[3].audit?.entries?.at(-1);check(entry,'audit_missing');
  const stamp=Date.parse(entry.at);
  check(Number.isFinite(stamp)&&stamp>=Date.parse(http.started)&&stamp<=Date.parse(http.finished),'audit_time_outside_request');
  const expectedEntry={sequence:total,at:entry.at,actor:session.user_id,project:state.project,action:http.action,resources:[http.resource],revision:before.revision+1,policy:{version:1,rule:'project_catalog_folder_cas_v1',parameters_sha256:sha(canonical(parameters))},outcome:'committed'};
  equal(entry,expectedEntry,'audit_policy_or_identity_mismatch');
  row[2]=String(before.revision+1);
  row[3].audit={total,entries:[...(row[3].audit?.entries||[]),expectedEntry].slice(-512)};
  if(Object.keys(organization.folders).length||Object.keys(organization.assignments).length)row[3].organization=organization;else delete row[3].organization;
  equal(expected,post,'unexpected_full_database_delta');
  fs.writeFileSync(path.join(out,`step-${step}.expected-parameters.json`),canonical(parameters),{flag:'wx'});
 }
 fs.writeFileSync(path.join(out,`step-${step}.expected-full-state.json`),canonical(expected),{flag:'wx'});
 process.stdout.write(JSON.stringify({status:'FULL_PRE_DERIVED_STATE_VERIFIED',step,mutation:http.status===303,all_rows_compared:true,policy_derived:http.status===303})+'\n');
}catch(error){process.stderr.write(error.message+'\n');process.exitCode=1;}
