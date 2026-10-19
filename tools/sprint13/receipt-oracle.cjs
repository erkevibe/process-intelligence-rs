'use strict';
// Independent receipt binding. Snapshot rows are arrays of strings/integer tokens,
// so the Rust Snapshot serialization domain needs no floating-point approximation.
const fs=require('node:fs'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {parseExact,Decimal,exactInteger}=require('./historical-state-oracle.cjs');
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const read=p=>parseExact(fs.readFileSync(p,'utf8'));
function scalarArray(value){
 if(Array.isArray(value))return '['+value.map(scalarArray).join(',')+']';
 if(value instanceof Decimal){assert.match(value.raw,/^-?(0|[1-9][0-9]*)$/);return value.raw;}
 assert.ok(value===null||typeof value==='string'||typeof value==='boolean');return JSON.stringify(value);
}
function snapshotHash(snapshot){
 assert.deepEqual(Object.keys(snapshot).sort(),['rows','sequence']);
 assert.ok(Array.isArray(snapshot.rows)&&Array.isArray(snapshot.sequence));
 return sha(Buffer.from('{"rows":'+scalarArray(snapshot.rows)+',"sequence":'+scalarArray(snapshot.sequence)+'}'));
}
function identity(actual,expected){
 assert.deepEqual(Object.keys(actual).sort(),['database','database_oid','system_identifier']);
 for(const key of Object.keys(actual))assert.equal(actual[key],expected[key]);
}
function verify(planPath,receiptPath,cliPath,sourcePath,restorePath,archivePath){
 const plan=read(planPath),receipt=read(receiptPath),cli=read(cliPath),source=read(sourcePath),restore=read(restorePath);
 assert.equal(receipt.outcome,'cleanup_committed');assert.equal(cli.outcome,'cleanup_committed');
 assert.equal(receipt.physical_disk_shrink,false);assert.equal(cli.physical_disk_shrink,false);
 identity(receipt.source,source);identity(receipt.restore,restore);
 identity(plan.source,source);identity(plan.restore,restore);
 assert.equal(receipt.plan_sha256,sha(fs.readFileSync(planPath)));
 assert.equal(receipt.archive_sha256,plan.archive.sha256);
 assert.equal(receipt.archive_sha256,sha(fs.readFileSync(archivePath)));
 assert.equal(cli.receipt_sha256,sha(fs.readFileSync(receiptPath)));
 assert.equal(exactInteger(receipt.deleted_rows),String(plan.candidates.length));
 assert.equal(exactInteger(cli.deleted_rows),String(plan.candidates.length));
 const keys=new Set(plan.candidates.map(row=>row.key));assert.equal(keys.size,plan.candidates.length);
 let bytes=0n;for(const row of plan.candidates)bytes+=BigInt(exactInteger(row.logical_bytes));
 assert.equal(exactInteger(receipt.logical_bytes),bytes.toString());
 const post={rows:plan.pre.rows.filter(row=>!(row[0]==='kv'&&keys.has(row[1]))),sequence:plan.pre.sequence};
 assert.equal(plan.pre.rows.length-post.rows.length,plan.candidates.length);
 assert.equal(receipt.pre_sha256,snapshotHash(plan.pre));assert.equal(receipt.post_sha256,snapshotHash(post));
 assert.ok(typeof receipt.committed_utc==='string'&&Number.isFinite(Date.parse(receipt.committed_utc)));
 assert.deepEqual(Object.keys(receipt).sort(),['archive_sha256','committed_utc','deleted_rows','logical_bytes','outcome','physical_disk_shrink','plan_sha256','post_sha256','pre_sha256','restore','source']);
 return {status:'COMMITTED_RECEIPT_FULL_CONTRACT_BOUND',deleted_rows:plan.candidates.length,receipt_sha256:cli.receipt_sha256,pre_sha256:receipt.pre_sha256,post_sha256:receipt.post_sha256,
  limits:['Receipt digest domain is reconstructed independently from the verified plan; complete actual SQL PRE/POST values are checked by a separate oracle','No physical disk shrink or SQL wire boundary inference']};
}
module.exports={scalarArray,snapshotHash,verify};
if(require.main===module){try{assert.equal(process.argv.length,8);console.log(JSON.stringify(verify(...process.argv.slice(2))));}catch{console.error('receipt_contract_mismatch');process.exitCode=1;}}
