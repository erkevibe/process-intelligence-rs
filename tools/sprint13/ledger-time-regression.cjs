'use strict';
// Root-authored finite checks of QA's OLD-ledger expected-time conversion.
// Replays immutable closed capture bytes; never opens PostgreSQL or changes data.
const assert=require('node:assert/strict'),fs=require('node:fs'),crypto=require('node:crypto');
const {parseExact,ledgerExpectedUTC,valueDigest,run}=require('./historical-state-oracle.cjs');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const sourcePath=require.resolve('./historical-state-oracle.cjs');
const sourceSha=sha(fs.readFileSync(sourcePath));
assert.equal(sourceSha,'a90d3fa1b487f1fd2637a21f75971f37e59e52412e39d89b2d78de260b6e4c91');
let checks=0;
const row=t=>parseExact(JSON.stringify({version:1,name:'baseline_v1',checksum:'fixture',applied_at:t}));
const expected='2026-10-10T12:04:14.781636+00:00';
for(const t of ['2026-10-10T17:04:14.781636+05:00',expected,'2026-10-10T12:04:14.781636Z','2026-10-10T07:04:14.781636-05:00']){
 assert.equal(ledgerExpectedUTC(row(t)).applied_at,expected);checks++;
}
for(const t of ['2026-10-10T17:04:14.781635+05:00','2026-10-10T17:04:14.781637+05:00']){
 assert.notEqual(valueDigest(ledgerExpectedUTC(row(t))),valueDigest(ledgerExpectedUTC(row('2026-10-10T17:04:14.781636+05:00'))));checks++;
}
for(const t of ['2026-02-30T17:04:14.781636+05:00','2026-10-10T24:04:14+05:00','2026-10-10T17:60:14+05:00','2026-10-10T17:04:60+05:00','2026-10-10T17:04:14+16:00','2026-10-10T17:04:14+05:60','2026-10-10T17:04:14.7816361+05:00','2026-10-10T17:04:14','not-a-time']){
 assert.throws(()=>ledgerExpectedUTC(row(t)));checks++;
}
for(const [input,result] of [['2026-01-01T00:00:00.000001+05:00','2025-12-31T19:00:00.000001+00:00'],['2026-10-10T17:04:14.781630+05:00','2026-10-10T12:04:14.78163+00:00'],['2026-10-10T17:04:14.000000+05:00','2026-10-10T12:04:14+00:00']]){
 assert.equal(ledgerExpectedUTC(row(input)).applied_at,result);checks++;
}
const original=row('2026-10-10T17:04:14.781636+05:00'),converted=ledgerExpectedUTC(original);
assert.equal(original.applied_at,'2026-10-10T17:04:14.781636+05:00');checks++;
for(const field of ['version','name','checksum']){assert.equal(converted[field],original[field]);checks++;}
for(const field of ['name','checksum']){assert.notEqual(valueDigest({...converted,[field]:'changed'}),valueDigest(converted));checks++;}
const v2={...original,version:parseExact('2')};assert.equal(ledgerExpectedUTC(v2),v2);checks++;
async function main(){
 const [legacyValues,capture,sequence]=process.argv.slice(2);assert.equal(process.argv.length,5);
 const actual=await run({mode:'original',legacyValues,capture,sequence});
 assert.equal(actual.status,'FULL_ORIGINAL_TYPED_STATE_MATCHED');assert.equal(actual.projects,10);checks++;
 assert.equal(sha(fs.readFileSync(sourcePath)),sourceSha);
 console.log(JSON.stringify({status:'OLD_LEDGER_EXPECTED_UTC_AND_CLOSED_CAPTURE_REGRESSION_PASSED',checks,oracle_sha256:sourceSha,closed_capture:actual.capture,
  limits:['Closed historical02 capture replay only; prior failed runtime remains failed','All12 KV+ledger1+exactsequence compared; no migration, SQL, forward, fault, cleanup or recovery acceptance','Only OLD expected ledger1 timestamp converted; actual capture bytes and all Auth/repository fields untouched']}));
}
main().catch(()=>{process.stderr.write('Ledger expected-time regression failed; retained private evidence.\n');process.exitCode=1;});
