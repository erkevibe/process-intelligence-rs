'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {parseExact}=require('./historical-state-oracle.cjs');
const {snapshotHash,verify}=require('./receipt-oracle.cjs');
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const out=path.resolve(process.argv[2]||'');assert.match(out.replace(/\\/g,'/'),/\/\.local\/sprint13\/root\/[a-z0-9-]+$/);
const rust=fs.readFileSync(process.argv[3],'utf8').match(/^S13_RECEIPT_SNAPSHOT_CALIBRATION ([a-f0-9]{64})$/gm);
assert.equal(rust?.length,1);const rustHash=rust[0].split(' ')[1];
const row=['kv','fixture/Ж𐍈\n\t"\\',7,'abc'];
const raw='{"rows":['+JSON.stringify(row)+',["marker","p",11,"source","ddl"]],"sequence":["bigint",1,1,9223372036854775807,1,1,false,63,true]}';
const snapshot=parseExact(raw);assert.equal(snapshotHash(snapshot),rustHash);
assert.throws(()=>snapshotHash(parseExact(raw.replace(',7,',',7.0,'))));
const save=(name,body)=>{const p=path.join(out,name);fs.writeFileSync(p,body,{flag:'wx'});return p;};
const source={system_identifier:'123',database_oid:'12',database:'fixture_source'},restore={system_identifier:'123',database_oid:'13',database:'fixture_restore'};
const sourcePath=save('source.json',JSON.stringify(source)),restorePath=save('restore.json',JSON.stringify(restore));
const archive=save('archive.dump','BENIGN_SYNTHETIC_NOT_POSTGRES_ARCHIVE');
const archiveSha=hash(fs.readFileSync(archive));
const planPath=save('plan.json','{"pre":'+raw+',"candidates":'+JSON.stringify([{key:row[1],logical_bytes:12}])+',"source":'+JSON.stringify(source)+',"restore":'+JSON.stringify(restore)+',"archive":{"sha256":"'+archiveSha+'"}}');
const receipt={outcome:'cleanup_committed',source,restore,plan_sha256:hash(fs.readFileSync(planPath)),archive_sha256:archiveSha,pre_sha256:rustHash,
 post_sha256:snapshotHash({rows:snapshot.rows.slice(1),sequence:snapshot.sequence}),deleted_rows:1,logical_bytes:12,committed_utc:'2026-01-01T00:00:00Z',physical_disk_shrink:false};
let serial=0,checks=2;
function pair(value,mutateCli){
 const n=++serial,receiptPath=save('receipt-'+n+'.json',JSON.stringify(value));
 const cli={outcome:'cleanup_committed',deleted_rows:1,receipt_sha256:hash(fs.readFileSync(receiptPath)),physical_disk_shrink:false};
 if(mutateCli)mutateCli(cli);
 const cliPath=save('cli-'+n+'.json',JSON.stringify(cli));
 return ()=>verify(planPath,receiptPath,cliPath,sourcePath,restorePath,archive);
}
assert.equal(pair(receipt)().status,'COMMITTED_RECEIPT_FULL_CONTRACT_BOUND');checks++;
for(const [field,value] of [['outcome','other'],['plan_sha256','0'.repeat(64)],['archive_sha256','0'.repeat(64)],['pre_sha256','0'.repeat(64)],['post_sha256','0'.repeat(64)],['deleted_rows',2],['logical_bytes',13],['physical_disk_shrink',true],['committed_utc','invalid']]){
 assert.throws(pair({...receipt,[field]:value}));checks++;
}
assert.throws(pair({...receipt,source:{...source,database_oid:'99'}}));checks++;
assert.throws(pair({...receipt,restore:{...restore,database:'other'}}));checks++;
assert.throws(pair({...receipt,unexpected:true}));checks++;
for(const mutate of [cli=>{cli.receipt_sha256='0'.repeat(64);},cli=>{cli.deleted_rows=2;},cli=>{cli.outcome='other';}]){assert.throws(pair(receipt,mutate));checks++;}
console.log(JSON.stringify({status:'RUST_SNAPSHOT_DOMAIN_AND_RECEIPT_NEGATIVE_REGRESSIONS_PASSED',checks,rust_snapshot_sha256:rustHash,
 limits:['Public synthetic arrays/scalars only; not a valid production archive or database','Actual committed cleanup and complete SQL state still require separate cases']}));
