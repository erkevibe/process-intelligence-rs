// Guard regressions for executable provenance and rejection of false manual PASS.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import crypto from 'node:crypto';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'pi-xes-tools-'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const command=(file,args)=>spawnSync(process.execPath,[file,...args],{encoding:'utf8',timeout:10000,windowsHide:true});
// Falsified class bytes must be rejected before java starts, even if the rest
// of the manifest is syntactically valid and the claimed build says success.
const build=path.join(root,'build');fs.mkdirSync(path.join(build,'classes'),{recursive:true});fs.mkdirSync(path.join(build,'deps'));
fs.writeFileSync(path.join(build,'classes','Fake.class'),'modified');
fs.writeFileSync(path.join(build,'build-proof.json'),JSON.stringify({files:[{path:'classes/Fake.class',bytes:8,sha256:sha('original')}]}));
let run=command('tools/oracle/run-xes-reference.mjs',['missing-jdk',build,'fixtures/oracle-xes',path.join(root,'out')]);
assert.notEqual(run.status,0);assert.match(run.stderr,/Build file identity changed/);assert.equal(fs.existsSync(path.join(root,'out')),false);
// A class not listed in the manifest cannot enter the executable classpath.
fs.writeFileSync(path.join(build,'build-proof.json'),JSON.stringify({files:[]}));
run=command('tools/oracle/run-xes-reference.mjs',['missing-jdk',build,'fixtures/oracle-xes',path.join(root,'out')]);
assert.notEqual(run.status,0);assert.match(run.stderr,/lacks captured hash/);
// A manifest cannot escape its build root.
fs.writeFileSync(path.join(build,'build-proof.json'),JSON.stringify({files:[{path:'../outside',bytes:0,sha256:sha('')}]}));
run=command('tools/oracle/run-xes-reference.mjs',['missing-jdk',build,'fixtures/oracle-xes',path.join(root,'out')]);
assert.notEqual(run.status,0);assert.match(run.stderr,/escaped root/);
// Corpus generation is immutable and preserves literal expectations.
const corpus=path.join(root,'corpus');run=command('tools/oracle/freeze-xes-corpus.mjs',[corpus]);assert.equal(run.status,0);
const bytes=fs.readFileSync(path.join(corpus,'corpus.json'));run=command('tools/oracle/freeze-xes-corpus.mjs',[corpus]);assert.notEqual(run.status,0);assert.deepEqual(fs.readFileSync(path.join(corpus,'corpus.json')),bytes);
const frozen=JSON.parse(bytes);assert.equal(frozen.fixtures.length,10);assert.deepEqual(frozen.fixtures.find(f=>f.id==='reverse-ties').timestamp_sequence,['A','C','B']);
for(const f of frozen.fixtures)assert.equal(sha(fs.readFileSync(path.join(corpus,f.id+'.xes'))),f.sha256);
console.log(JSON.stringify({passed:true,checks:5,temporary_directory:root,cleanup:'retained isolated test evidence'}));
