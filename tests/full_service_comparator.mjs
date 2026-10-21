import assert from 'node:assert/strict';
import {rustLog, javaLog, differences, coreProjection, previewProjection, compareAccepted} from '../tools/oracle/compare-full-service.mjs';

const rustAttr = (key, type, content) => ({key, value: {type, content}, own_attributes: null});
const javaAttr = (key, type, value) => ({key, type, value});
const rust = {attributes: [rustAttr('concept:name', 'String', 'Log')], classifiers: [{name:'Activity lifecycle',keys:['concept:name','lifecycle:transition']}], extensions: [], global_trace_attrs: null, global_event_attrs: null, traces: [{attributes: [rustAttr('concept:name','String','Trace')], events: [{attributes: [rustAttr('time:timestamp','Date','2024-01-01T05:00:00.123456+05:00'),rustAttr('cost','Float',1.25),rustAttr('concept:name','String','A')]}]}]};
const legacy = {attributes: [javaAttr('concept:name','string','Log')],classifiers:rust.classifiers,extensions:[],global_trace_attributes:[],global_event_attributes:[],traces:[{attributes:[javaAttr('concept:name','string','Trace')],events:[{attributes:[javaAttr('concept:name','string','A'),javaAttr('cost','float',1.25),javaAttr('time:timestamp','date',1704067200123)]}]}]};
assert.deepEqual(rustLog(rust), javaLog(legacy));
const changed = structuredClone(legacy);
changed.traces[0].events[0].attributes[1].value = 2.25;
assert(differences(rustLog(rust), javaLog(changed)).some(d => d.path.endsWith('.value') && d.left === 1.25 && d.right === 2.25));
changed.traces[0].events[0].attributes[1].value = 1.25;
changed.classifiers[0].keys.reverse();
assert(differences(rustLog(rust), javaLog(changed)).some(d => d.path.includes('.classifiers[0].keys')));

const preview = {log:{name:'Log',cases:[{id:'case-0',name:'Trace',events:[{ordinal:0,activity:'A',lifecycle:'complete',timestamp:'2024-01-01T00:00:00.123456Z'}]}]},changes:[{case_index:0,event_index:0,action:'default_lifecycle'}],projection_report:{omitted_event_attributes:1}};
const imported = structuredClone(legacy);
imported.traces[0].events[0].attributes.push(javaAttr('lifecycle:transition','string','complete'));
assert.deepEqual(coreProjection(javaLog(imported)), previewProjection(preview));
const proof = compareAccepted(rust, preview, {log:imported}, 'submillisecond');
assert.equal(proof.timestamp_precision_differences.length, 1);
assert.equal(proof.retained_source_metadata_except_declared_default, 'equal');
const omitted = structuredClone(imported);
omitted.traces[0].events[0].attributes = omitted.traces[0].events[0].attributes.filter(a => a.key !== 'cost');
assert.throws(() => compareAccepted(rust, preview, {log:omitted}, 'submillisecond'), /metadata differs/);
const wrongOrder = structuredClone(legacy);
wrongOrder.traces[0].events.push({attributes:[javaAttr('concept:name','string','B')]});
assert(differences(javaLog(legacy), javaLog(wrongOrder)).some(d => d.path.includes('.events.length')));

const rawNoName = structuredClone(rust); rawNoName.attributes = [];
const noNamePreview = structuredClone(preview); noNamePreview.log.name = null;
noNamePreview.log.cases[0].events[0].timestamp = '2024-01-01T00:00:00.123Z';
rawNoName.traces[0].events[0].attributes[0].value.content = '2024-01-01T00:00:00.123Z';
const defaulted = structuredClone(imported); defaulted.attributes[0].value = 'Anonymous log imported from ';
assert.equal(compareAccepted(rawNoName, noNamePreview, {log:defaulted}, 'default-log-name').core_field_differences.length, 1);
defaulted.attributes[0].value = 'Invented default';
assert.throws(() => compareAccepted(rawNoName, noNamePreview, {log:defaulted}, 'default-log-name'));
assert.throws(() => differences({a:1},{a:2},'$',Array.from({length:256},()=>({}))), /difference cap/);
console.log('Full-service field comparator: types, metadata loss, classifier key order, event order, precision, default-name and bounded failure checks passed');
