'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{verify}=require('./audit-retention-oracle.cjs');
function text(file){assert.ok(fs.statSync(file).size<=16*1024*1024);return fs.readFileSync(file,'utf8');}
function state(file){
 const auth=[],other=text(file).trim().split(/\r?\n/).filter(line=>{
  if(!line.startsWith('['))return true;const row=JSON.parse(line);
  if(row[0]==='pi_kv'&&row[1].key==='auth'){auth.push(row[1]);return false;}return true;
 });
 assert.equal(auth.length,1);return {auth:{version:auth[0].version,document:auth[0].document},other};
}
try{
 assert.equal(process.argv.length,3);const root=process.argv[2];
 const read=name=>JSON.parse(text(path.join(root,name)));
 const pre=state(path.join(root,'audit-pre.stdout')),at512=state(path.join(root,'audit-at512.stdout')),at513=state(path.join(root,'audit-at513.stdout'));
 assert.deepEqual(pre.other,at512.other);assert.deepEqual(pre.other,at513.other);
 const scope=read('audit-retention-private.json'),ops=[...read('audit-at512-operations.json'),...read('audit-at513-operations.json')];
 const headers=pre.other.filter(line=>line.startsWith('[')).map(JSON.parse).filter(row=>row[0]==='pi_projects'&&row[1].project_id===scope.project);
 assert.equal(headers.length,1);const repositoryAudit=headers[0][1].document.audit||{total:0,entries:[]};
 const proof=verify(pre.auth,at512.auth,at513.auth,read('audit-baseline-export.json'),read('audit-at512-export.json'),read('audit-at513-export.json'),ops,scope.project,scope.actor,repositoryAudit);
 process.stdout.write(JSON.stringify({...proof,all_non_auth_raw_rows_exact:true})+'\n');
}catch{process.stderr.write('audit_retention_contract_failed\n');process.exitCode=1;}
