'use strict';
const assert=require('node:assert/strict'),{verify}=require('../tools/audit-retention-oracle.cjs');
const project='project-a',actor='user-a',t=1800000000000;
const legacy=Array.from({length:510},(_,i)=>({sequence:i+1,at:new Date(t-1000+i).toISOString(),actor,project,action:'project_renamed',resources:[project],revision:i+1,policy:{version:1,rule:'owner_project_name_cas_v1',parameters_sha256:'a'.repeat(64)},outcome:'committed'}));
const pre={version:700,document:{projects:{[project]:{name:'before',revision:800,members:{[actor]:'owner'}}},users:{[actor]:{fixture:'retained-user'}},sessions:{old:{fixture:'retained-session'}},audit:{[project]:{total:510,entries:legacy}}}};
const operations=Array.from({length:3},(_,i)=>({name:'s11-retention-'+String(i+1).padStart(3,'0'),expected_revision:800+i,http_status:303,started_utc:new Date(t+i*2000).toISOString(),ended_utc:new Date(t+i*2000+1000).toISOString()}));
// Literal source-derived golden states; do not generate the reference with the oracle.
const hashes=['d3608bc53d0ecab36b0c65c715b09d4fe2a5bd54beabda62aaec4352d88138d7','b27e704f34e3854172b1f6c2b34b0d5ee89e72fcd0d42feb30b444112f162ea2','798d15b150a9a665c10444897c16f6f28c4b1be18b1458d3b51251621501bb1a'];
const added=hashes.map((hash,i)=>({sequence:511+i,at:new Date(t+i*2000+500).toISOString(),actor,project,action:'project_renamed',resources:[project],revision:801+i,policy:{version:1,rule:'owner_project_name_cas_v1',parameters_sha256:hash},outcome:'committed'}));
const at512=structuredClone(pre);at512.version=702;at512.document.projects[project].name='s11-retention-002';at512.document.projects[project].revision=802;at512.document.audit[project]={total:512,entries:[...legacy,...added.slice(0,2)]};
const at513=structuredClone(pre);at513.version=703;at513.document.projects[project].name='s11-retention-003';at513.document.projects[project].revision=803;at513.document.audit[project]={total:513,entries:[...legacy.slice(1),...added]};
const repositoryAudit={total:1,entries:[{fixture:'untouched-repository-event'}]};
const baseline={schema_version:2,scope:'server business mutations committed; legacy policy/outcome unknown; client project-backup history explicitly unverified; retained last512 per scope',project_id:project,project_total:1,project_dropped:0,project_entries:repositoryAudit.entries,auth_owner_projection:{scope:'current project owner; successful auth mutations; per-project last512',retention_capacity:512,total:510,dropped:0,visible_entries:510,entries:legacy},deletion_owner_projection:{scope:'former owner only; deletion witnesses, no deleted payloads',retention_capacity:512,total:0,dropped:0,entries:[]}};
const e512=structuredClone(baseline),e513=structuredClone(baseline);e512.auth_owner_projection={...structuredClone(baseline.auth_owner_projection),total:512,dropped:0,visible_entries:512,entries:at512.document.audit[project].entries};e513.auth_owner_projection={...structuredClone(baseline.auth_owner_projection),total:513,dropped:1,visible_entries:512,entries:at513.document.audit[project].entries};
const args=[pre,at512,at513,baseline,e512,e513,operations,project,actor,repositoryAudit];assert.equal(verify(...args).dropped_at513,1);
const mutations=[
 a=>{a[2].document.users[actor].fixture='changed';},
 a=>{a[2].document.audit[project].entries[0].sequence=1;},
 a=>{a[1].document.audit[project].entries.at(-1).policy.rule='wrong';},
 a=>{a[5].auth_owner_projection.dropped=0;},
 a=>{a[5].project_entries=[];},
 a=>{a[6][0].expected_revision=0;},
 a=>{a[4].auth_owner_projection.entries.at(-1).at=new Date(t+60000).toISOString();},
 a=>{a[2].version++;}
 ,a=>{a[3].project_entries=[];}
 ,a=>{a[3].deletion_owner_projection.entries=[{fixture:'unexpected'}];}
];
for(const mutate of mutations){const copy=structuredClone(args);mutate(copy);assert.throws(()=>verify(...copy));}
process.stdout.write(JSON.stringify({status:'FINITE_RETENTION_ORACLE_REGRESSION_PASSED',scenarios:11,limits:['Synthetic full-PRE/512/513 mutation refusals, not live audit producer proof']})+'\n');
