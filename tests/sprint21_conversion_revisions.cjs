'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const {parseRevision, shouldApplyRevision, applyTransport} = require('../static/conversions.js');

test('strictly increasing canonical u64 revisions', () => {
  assert.equal(parseRevision('0'), 0n);
  assert.equal(parseRevision('18446744073709551615'), 18446744073709551615n);
  assert.equal(shouldApplyRevision('0', '1'), true);
  assert.equal(shouldApplyRevision('42', '41'), false);
  assert.equal(shouldApplyRevision('42', '42'), false);
  assert.equal(shouldApplyRevision('9007199254740992', '9007199254740993'), true);
  assert.equal(shouldApplyRevision('9007199254740993', '9007199254740992'), false);
  assert.equal(shouldApplyRevision('18446744073709551614', '18446744073709551615'), true);
  assert.equal(shouldApplyRevision('18446744073709551615', '18446744073709551615'), false);
});
test('invalid values fail closed without coercion or Number rounding', () => {
  const bad = [undefined, null, 0, 1n, {}, [], '', ' ', ' 1', '1 ', '+1', '-1', '01', '00', '1.0', '1e3', 'NaN', 'Infinity', '0x10', '18446744073709551616', '999999999999999999999', '١', '1\n'];
  for (const value of bad) {
    assert.equal(parseRevision(value), null, String(value));
    assert.equal(shouldApplyRevision('0', value), false, String(value));
    assert.equal(shouldApplyRevision(value, '1'), false, String(value));
  }
});
let JSDOM;
try { ({JSDOM} = require('jsdom')); } catch { /* Optional installed DOM library; never install for this test. */ }
test('DOM transport accepts newer once, ignores stale/reconnect and leaves watcher attached', {skip: !JSDOM && 'jsdom is not installed; actual browser acceptance remains required'}, () => {
  const dom = new JSDOM('<!doctype html><html><body><div id="watcher" data-init="stable"><article id="conversion-job-7" data-revision="9007199254740992"><p>Queued</p></article></div><div hidden id="conversion-transport-job-7"></div></body></html>');
  const doc = dom.window.document;
  const watcher = doc.getElementById('watcher');
  const transport = doc.getElementById('conversion-transport-job-7');
  const envelope = (revision, text = 'Done', job = 'job-7', article = 'conversion-job-7') => {
    transport.innerHTML = `<template data-conversion-update data-job-id="${job}"><article id="${article}" data-revision="${revision}"><p>${text}</p></article></template>`;
  };
  envelope('9007199254740993');
  assert.equal(applyTransport(transport, doc), true);
  assert.equal(doc.getElementById('conversion-job-7').getAttribute('data-revision'), '9007199254740993');
  assert.equal(doc.getElementById('watcher'), watcher);
  assert.equal(watcher.getAttribute('data-init'), 'stable');
  assert.equal(transport.children.length, 0);
  for (const revision of ['9007199254740992', '9007199254740993', '18446744073709551616', 'invalid']) {
    envelope(revision, 'Stale');assert.equal(applyTransport(transport, doc), false);
    assert.equal(doc.getElementById('conversion-job-7').textContent, 'Done');assert.equal(transport.children.length, 0);
  }
  envelope('9007199254740994', 'Wrong job', 'job-8');assert.equal(applyTransport(transport, doc), false);
  envelope('9007199254740994', 'Wrong article', 'job-7', 'conversion-job-8');assert.equal(applyTransport(transport, doc), false);
  transport.innerHTML = '<template data-conversion-update data-job-id="job-7"><article id="conversion-job-7" data-revision="9007199254740994">Bad</article><article>Extra</article></template>';
  assert.equal(applyTransport(transport, doc), false);
  assert.equal(doc.getElementById('conversion-job-7').textContent, 'Done');
  dom.window.close();
});
