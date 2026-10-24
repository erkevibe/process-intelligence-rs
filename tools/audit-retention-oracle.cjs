'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto');
const sha=s=>crypto.createHash('sha256').update(s).digest('hex');
function expected(pre,project,actor,operations,actualEntries){
 const document=structuredClone(pre.document),p=document.projects[project];
 assert.ok(p&&p.members[actor]==='owner');
 const before=structuredClone(document.audit?.[project]||{total:0,entries:[]});
 assert.ok(Number.isSafeInteger(pre.version)&&Number.isSafeInteger(p.revision)&&Number.isSafeInteger(before.total)&&before.total<512);
 assert.equal(before.entries.length,before.total);
 const entries=[...before.entries],times=new Map(actualEntries.map(e=>[e.sequence,e.at]));
 assert.equal(times.size,actualEntries.length);
 for(let i=0;i<operations.length;i++){
  const op=operations[i],revision=p.revision,sequence=before.total+i+1;
  assert.equal(op.expected_revision,revision);assert.equal(op.http_status,303);
  assert.match(op.name,/^s11-retention-\d{3}$/);assert.equal(op.name,'s11-retention-'+String(i+1).padStart(3,'0'));
  const at=times.get(sequence),ms=Date.parse(at),start=Date.parse(op.started_utc),end=Date.parse(op.ended_utc);
  assert.ok(Number.isFinite(ms)&&Number.isFinite(start)&&Number.isFinite(end)&&end>=start&&end-start<=15000&&ms>=start&&ms<=end);
  p.name=op.name;p.revision++;
  const parameters={expected_revision:revision,name_bytes:Buffer.byteLength(op.name),name_sha256:sha(op.name)};
  entries.push({sequence,at,actor,project,action:'project_renamed',resources:[project],revision:p.revision,policy:{version:1,rule:'owner_project_name_cas_v1',parameters_sha256:sha(JSON.stringify(parameters))},outcome:'committed'});
 }
 document.audit||={};document.audit[project]={total:before.total+operations.length,entries:entries.slice(-512)};
 return {version:pre.version+operations.length,document};
}
function projection(trail){
 return {scope:'current project owner; successful auth mutations; per-project last512',retention_capacity:512,total:trail.total,dropped:Math.max(0,trail.total-trail.entries.length),visible_entries:trail.entries.length,entries:trail.entries};
}
function verify(pre,at512,at513,baseline,export512,export513,operations,project,actor,repositoryAudit){
 const initial=pre.document.audit?.[project]||{total:0,entries:[]},needed=512-initial.total;
 assert.deepEqual(baseline.auth_owner_projection,projection(initial));
 assert.deepEqual(Object.keys(baseline).sort(),['schema_version','scope','project_id','project_total','project_dropped','project_entries','auth_owner_projection','deletion_owner_projection'].sort());
 assert.equal(baseline.scope,'server business mutations committed; legacy policy/outcome unknown; client project-backup history explicitly unverified; retained last512 per scope');
 assert.ok(repositoryAudit&&Number.isSafeInteger(repositoryAudit.total)&&Array.isArray(repositoryAudit.entries));
 assert.equal(baseline.project_total,repositoryAudit.total);
 assert.equal(baseline.project_dropped,Math.max(0,repositoryAudit.total-repositoryAudit.entries.length));
 assert.deepEqual(baseline.project_entries,repositoryAudit.entries);
 const deletions=pre.document.deletions?.[actor]||{total:0,entries:[]};
 assert.deepEqual(baseline.deletion_owner_projection,{scope:'former owner only; deletion witnesses, no deleted payloads',retention_capacity:512,total:deletions.total,dropped:Math.max(0,deletions.total-deletions.entries.length),entries:deletions.entries});
 assert.ok(needed>=1&&needed<=512);assert.equal(operations.length,needed+1);
 const allEntries=[...export512.auth_owner_projection.entries,...export513.auth_owner_projection.entries];
 // Each retained timestamp is tied to its actual corresponding request.
 const bySequence=new Map();for(const entry of allEntries){if(bySequence.has(entry.sequence))assert.deepEqual(entry,bySequence.get(entry.sequence));bySequence.set(entry.sequence,entry);}
 const e512=expected(pre,project,actor,operations.slice(0,needed),[...bySequence.values()]);
 const e513=expected(pre,project,actor,operations,[...bySequence.values()]);
 assert.deepEqual(at512,e512);assert.deepEqual(at513,e513);
 const expected512=structuredClone(baseline),expected513=structuredClone(baseline);
 expected512.auth_owner_projection=projection(e512.document.audit[project]);expected513.auth_owner_projection=projection(e513.document.audit[project]);
 assert.deepEqual(export512,expected512);assert.deepEqual(export513,expected513);
 assert.equal(export512.schema_version,2);assert.equal(export512.project_id,project);
 assert.equal(export512.auth_owner_projection.total,512);assert.equal(export513.auth_owner_projection.total,513);
 assert.deepEqual(export513.auth_owner_projection.entries.slice(0,-1),export512.auth_owner_projection.entries.slice(1));
 return {status:'FINITE_AUTH_OWNER_RETENTION_512_513_VERIFIED',initial_total:initial.total,actual_renames:operations.length,retained:512,dropped_at513:1,whole_auth_derived_from_pre:true,all_export_fields_verified:true,limits:['One producer/project/Auth-owner scope; not all audit producers or R3 acceptance','Entry timestamps bounded by actual per-request intervals, not predicted exact clock']};
}
module.exports={verify,expected,projection};
