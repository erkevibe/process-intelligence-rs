const assert = require('node:assert/strict');
const {runQuality} = require('../static/quality.js');
(async () => {
  const old = {textContent:'старые 100%'};
  const doc = {getElementById:()=>old};
  let release;
  const pending = runQuality(()=>new Promise(resolve=>{release=resolve;}),doc);
  assert(!old.textContent.includes('100%'));
  const next = {textContent:'новая оценка'};
  doc.getElementById = ()=>next;
  release(); await pending;
  assert.equal(next.textContent,'новая оценка');
  await runQuality(async()=>{throw Error('denied')},doc);
  assert(next.textContent.includes('Оценка не получена'));
  assert(!next.textContent.includes('новая оценка'));
  // Datastar resolves non-200 responses under retry:'never' without a patch.
  next.textContent = 'старый результат';
  await runQuality(async()=>{},doc);
  assert(next.textContent.includes('Оценка не получена'));
  assert(!next.textContent.includes('Считаем новую оценку'));
  assert(!next.textContent.includes('старый результат'));
  // Datastar morphs can patch the same section instead of replacing its object.
  await runQuality(async()=>{next.textContent='успешная оценка после morph'},doc);
  assert.equal(next.textContent,'успешная оценка после morph');
  let called=false;
  await runQuality(async()=>{called=true},{getElementById:()=>null});
  assert.equal(called,false);
  console.log('quality UI stale-result and failed-request controls PASS');
})().catch(error=>{console.error(error);process.exitCode=1;});
