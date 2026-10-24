// Pure field comparison support. No calendar or filter algorithm is implemented.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseObservation, fieldDifferences, sha256} from './compare-public-service.mjs';
export {assert, fieldDifferences, sha256};
export const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const same = (a,b) => fieldDifferences(a,b).length === 0;
export const exactInteger = value => {
  assert(typeof value === 'bigint' || Number.isSafeInteger(value), 'exact observed integer');
  return BigInt(value);
};
export function readJson(file, expected = null) {
  const full = path.resolve(repository, file);
  assert(fs.statSync(full).size <= 4*1024*1024, 'bounded JSON input');
  const bytes = fs.readFileSync(full);
  if (expected !== null) assert.equal(sha256(bytes), expected.toLowerCase(), 'actual source bytes SHA');
  return {file:full, bytes, value:parseObservation(bytes.toString('utf8'))};
}
export function fieldChecks(expected, observed) {
  return Object.fromEntries(Object.entries(expected).map(([key,value]) => {
    assert(Object.hasOwn(observed,key), 'every frozen hypothesis has an observed field: '+key);
    return [key,same(value,observed[key])];
  }));
}
export const all = checks => Object.values(checks).every(Boolean);
export function saveFresh(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, (_key,item) => typeof item === 'bigint' ? JSON.rawJSON(item.toString()) : item, 2)+'\n', {flag:'wx'});
}
export function runCorpus(profile, corpusSha, compare) {
  assert.equal(process.argv.length,5,'Java index, Rust index, NEW report JSON');
  const java=readJson(process.argv[2]), rust=readJson(process.argv[3]);
  const corpus=readJson('fixtures/'+profile+'/corpus.json',corpusSha);
  for (const index of [java.value,rust.value]) {
    assert.equal(index.corpus_sha256.toLowerCase(),corpusSha);
    assert.equal(index.cases.length,corpus.value.cases.length,'complete finite corpus');
    assert.equal(new Set(index.cases.map(row=>row.id)).size,index.cases.length,'unique index identities');
    assert(same(index.cases.map(row=>row.id),corpus.value.cases.map(row=>row.id)),'frozen case order');
  }
  const cases=corpus.value.cases.map((spec,i)=>{
    const input=readJson(path.join('fixtures',profile,spec.file),spec.sha256).value;
    const jrow=java.value.cases[i],rrow=rust.value.cases[i];
    for(const row of [jrow,rrow]) for(const key of ['observation_path','native_record']) {
      assert(typeof row[key]==='string'&&!path.isAbsolute(row[key])&&!/^[A-Za-z]:/.test(row[key])&&!row[key].replaceAll('\\','/').split('/').includes('..'),'portable paths relative to index directory');
    }
    const j=readJson(path.resolve(path.dirname(java.file),jrow.observation_path),jrow.observation_sha256).value;
    const r=readJson(path.resolve(path.dirname(rust.file),rrow.observation_path),rrow.observation_sha256).value;
    const programs={java:'9fcc7d5d43918e389df240d44601c98a4d3aa9e7d0cbbd6d208304e0b574c7e2',rust:profile==='oracle-core-calendar'?'dab02678c7b216f85c4c8279c3757e428c571fe3ae88ffd1ec85083ad70c78d4':'2f821090681e72e925e46059ddff6c986cf232504ea6f3a6d075c1f7ccea313c'};
    for(const [side,index,row] of [['java',java,jrow],['rust',rust,rrow]]) {
      const native=readJson(path.resolve(path.dirname(index.file),row.native_record),row.native_record_sha256).value;
      assert.equal(native.program_sha256.toLowerCase(),programs[side],'actual pinned executable');
      assert.equal(native.native_exit,0);assert.equal(native.stdout_complete,true);assert.equal(native.stderr_complete,true);
      for(const flag of ['output_limit','capture_fault','drain_timeout']) assert.equal(native[flag],false,'closed bounded native capture');
    }
    for(const [row,value] of [[jrow,j],[rrow,r]]) {
      assert.equal(value.schema_version,1);assert.equal(value.id,spec.id);
      assert.equal(value.input_sha256.toLowerCase(),spec.sha256.toLowerCase(),'frozen raw input identity');
      assert.equal(row.input_sha256.toLowerCase(),spec.sha256.toLowerCase());
    }
    return {...compare(j,r,spec,input),java_observation_sha256:jrow.observation_sha256,rust_observation_sha256:rrow.observation_sha256};
  });
  const report={schema_version:1,status:cases.every(row=>row.all_frozen_hypotheses_match)?'ACTUAL_FINITE_COMPARISON_COMPLETED':'OBSERVED_WITH_FROZEN_HYPOTHESIS_DIFFERENCES',corpus_sha256:corpusSha,java_index_sha256:sha256(java.bytes),rust_index_sha256:sha256(rust.bytes),case_count:cases.length,cases,no_whole_R5_or_Core_parity_claim:true};
  saveFresh(process.argv[4],report);
  console.log(JSON.stringify({status:report.status,case_count:cases.length}));
}
