import assert from 'node:assert/strict';
import {parseObservation, typedAttribute, typedLog, fieldDifferences, compareSavedLogs, retainedSourceMetadata, compareMinimalPublic, comparePublicCase} from '../tools/oracle/compare-public-service.mjs';

const ra = (key, type, content) => ({key, value: {type, content}, own_attributes: null});
const ja = (key, type, value) => ({key, type, value});
const one = parseObservation('{"key":"cost","type":"int","value":9007199254740993}');
const two = parseObservation('{"key":"cost","type":"int","value":9007199254740992}');
// Ordinary JSON.parse incorrectly makes these DIFFERENT i64 observations equal.
assert.equal(JSON.parse('{"v":9007199254740993}').v, JSON.parse('{"v":9007199254740992}').v);
assert.equal(typedAttribute(one, 'java').value, '9007199254740993');
assert.notDeepEqual(typedAttribute(one, 'java'), typedAttribute(two, 'java'));
assert.equal(typedAttribute(parseObservation('{"key":"x","type":"int","value":-9223372036854775808}'), 'java').value, '-9223372036854775808');
assert.equal(typedAttribute(parseObservation('{"key":"x","type":"int","value":9223372036854775807}'), 'java').value, '9223372036854775807');
assert.throws(() => typedAttribute({key: 'x', type: 'int', value: 9007199254740993}, 'java'), /exact integer/);
assert.notDeepEqual(typedAttribute(ja('x', 'float', -0), 'java'), typedAttribute(ja('x', 'float', 0), 'java'));
assert.notDeepEqual(typedAttribute(ja('x', 'int', 1), 'java'), typedAttribute(ja('x', 'float', 1), 'java'));
assert.throws(() => typedAttribute(ja('x', 'float', Infinity), 'java'), /finite/);
assert.deepEqual(typedAttribute(parseObservation('{"key":"x","type":"float","value":100000000000000000000}'), 'java'), typedAttribute(ja('x', 'float', 1e20), 'java'));

const list = ja('items', 'list', [ja('item', 'int', 3), ja('item', 'int', 7)]);
assert.notDeepEqual(typedAttribute(list, 'java'), typedAttribute({...list, value: [...list.value].reverse()}, 'java'));
const dictionary = ja('address', 'container', [ja('z', 'string', 'last'), ja('a', 'string', 'first')]);
assert.deepEqual(typedAttribute(dictionary, 'java'), typedAttribute({...dictionary, value: [...dictionary.value].reverse()}, 'java'));
const child = {...ja('x', 'string', 'parent'), children: [ja('child', 'boolean', true)]};
assert.notDeepEqual(typedAttribute(child, 'java'), typedAttribute(ja('x', 'string', 'parent'), 'java'));

const raw = {attributes: [ra('concept:name', 'String', 'Log')], classifiers: [{name: 'Activity lifecycle', keys: ['concept:name', 'lifecycle:transition']}],
  traces: [{attributes: [ra('concept:name', 'String', 'case')], events: [{attributes: [ra('concept:name', 'String', 'A'), ra('time:timestamp', 'Date', '2024-01-01T05:00:00.123456789+05:00'), ra('cost', 'Int', one.value)]}]}]};
const saved = {attributes: [ja('concept:name', 'string', 'Log')], classifiers: raw.classifiers,
  traces: [{attributes: [ja('concept:name', 'string', 'case')], events: [{attributes: [ja('concept:name', 'string', 'A'), ja('time:timestamp', 'date', 1704067200123), one, ja('lifecycle:transition', 'string', 'complete')]}]}]};
const preview = {log: {name: 'Log', cases: [{id: 'case-0', name: 'case', events: [{ordinal: 0, activity: 'A', lifecycle: 'complete', timestamp: '2024-01-01T00:00:00.123456789Z'}]}]}, changes: [{case_index: 0, event_index: 0, action: 'default_lifecycle'}]};
const result = compareSavedLogs(raw, preview, saved);
assert.equal(result.retained_metadata_exact, false); // millisecond equality must NOT hide nanosecond loss
assert.equal(result.exact_field_differences.length, 1);
assert.match(result.exact_field_differences[0].path, /sub_millisecond_ns$/);
assert.deepEqual(result.field_differences_at_declared_millisecond_resolution, []);
assert.deepEqual(result.product_core_differences_at_declared_millisecond_resolution, []);
const wrongActivity = structuredClone(preview); wrongActivity.log.cases[0].events[0].activity = 'WRONG';
assert(compareSavedLogs(raw, wrongActivity, saved).product_core_differences_at_declared_millisecond_resolution.some(d => d.path.endsWith('.activity')));
const altered = structuredClone(saved); altered.traces[0].events[0].attributes[2] = two;
assert(compareSavedLogs(raw, preview, altered).field_differences_at_declared_millisecond_resolution.some(d => d.path.endsWith('.value')));
const reordered = structuredClone(saved); reordered.classifiers[0].keys.reverse();
assert(compareSavedLogs(raw, preview, reordered).field_differences_at_declared_millisecond_resolution.some(d => d.path.includes('classifiers')));
const changed = structuredClone(saved); changed.traces[0].events.push({attributes: [ja('concept:name', 'string', 'B')]});
assert(fieldDifferences(typedLog(saved, 'java'), typedLog(changed, 'java')).some(d => d.path.includes('events.length')));
const invalidIdentity = structuredClone(preview); invalidIdentity.log.cases[0].events[0].ordinal = 7;
assert.throws(() => retainedSourceMetadata(raw, invalidIdentity), /source event/);
const nullDifference = fieldDifferences({}, {field: null});
assert.equal(nullDifference[0].left_missing, true);
assert.equal(nullDifference[0].right_missing, false);
assert.notDeepEqual(fieldDifferences([], {}), []);
assert.throws(() => fieldDifferences({a: 1}, {a: 2}, '$', Array(512).fill({})), /difference cap/);
const digest = 'a'.repeat(64);
const rustObservation = {input_sha256: digest, raw_rust4pm: {status: 'ok', log: raw}, preview: {status: 'ok', value: preview}};
const publicObservation = {input_sha256: digest, status: 'ACTUAL_PUBLIC_MINIMAL_GATE_COMPLETED',
  service_identity: {sha256: '24900e3f31629f3337490b930d51fbe7b4c1436872ed184477ae580a17d61097'},
  proxy: {is_aop_proxy: true, target_class: 'org.apromore.service.impl.EventLogServiceImpl', advice: ['org.springframework.transaction.interceptor.TransactionInterceptor']},
  transaction_entries: [{actual_transaction_active: true}],
  first_readback: {id: 1, name: 'Public gate', reloaded_log: saved, apm_cache_class: 'some.actual.CacheClass'},
  reopened_readback: {id: 1, name: 'Public gate', reloaded_log: saved, apm_cache_class: null}};
assert.equal(compareMinimalPublic(rustObservation, publicObservation).saved_full_record_after_reopen_equal, true);
const unobservedTransaction = structuredClone(publicObservation); unobservedTransaction.transaction_entries = [];
assert.throws(() => compareMinimalPublic(rustObservation, unobservedTransaction), /active transaction/);
const inactiveTransaction = structuredClone(publicObservation); inactiveTransaction.transaction_entries[0].actual_transaction_active = false;
assert.throws(() => compareMinimalPublic(rustObservation, inactiveTransaction), /active transaction/);
const changedName = structuredClone(publicObservation);
// The fixture initially aliases both saved logs; detach before injecting drift.
changedName.first_readback.reloaded_log = structuredClone(changedName.first_readback.reloaded_log);
changedName.first_readback.reloaded_log.attributes[0].value = 'Log ';
assert.equal(compareMinimalPublic(rustObservation, changedName).saved_full_record_after_reopen_equal, false);
assert(compareMinimalPublic(rustObservation, changedName).saved_record_differences.some(d => d.left === 'Log ' && d.right === 'Log'));
const wrongFixture = structuredClone(rustObservation); wrongFixture.input_sha256 = 'b'.repeat(64);
assert.throws(() => compareMinimalPublic(wrongFixture, publicObservation), /same actual fixture/);
const wrongClass = structuredClone(publicObservation); wrongClass.service_identity.sha256 = 'c'.repeat(64);
assert.throws(() => compareMinimalPublic(rustObservation, wrongClass), /service class pin/);
const frozen = {id: 'rollback-example', sha256: digest, expected_source_hypothesis: {outcome: 'outer_rollback', log_delta: 0}};
const rollback = {...publicObservation, id: frozen.id, status: 'ACTUAL_PUBLIC_CASE_OBSERVED', parameters: frozen, outcome: 'outer_rollback',
  before: {database: {logs: 0, storage: 0, group_logs: 0}, files: [], cache: []},
  after: {database: {logs: 0, storage: 0, group_logs: 0}, files: [{relative: 'fixture.xes.gz', bytes: 20, sha256: digest}], cache: [{key: 'fixture', value_class: 'XLog'}]},
  reopened_before_read: {database: {logs: 0, storage: 0, group_logs: 0}}};
const rollbackResult = comparePublicCase(rustObservation, rollback, frozen);
assert.deepEqual(rollbackResult.actual_state_delta, {logs: 0, storage: 0, group_logs: 0, files: 1, cache_entries: 1});
assert.equal(rollbackResult.saved_full_record_after_reopen_equal, null);
assert.equal(rollbackResult.fields, null);
assert.notDeepEqual(rollbackResult.files_before_after_differences, []);
const retuned = structuredClone(rollback); retuned.parameters.expected_source_hypothesis.log_delta = 1;
assert.throws(() => comparePublicCase(rustObservation, retuned, frozen), /unchanged frozen parameters/);
const nullSpec = {...frozen, id: 'null-after-reopen', expected_source_hypothesis: {outcome: 'success'}};
const unavailable = {...publicObservation, id: nullSpec.id, status: 'ACTUAL_PUBLIC_CASE_OBSERVED', parameters: nullSpec, outcome: 'success',
  before: rollback.before, after: {...rollback.after, database: {logs: 1, storage: 1, group_logs: 1}},
  reopened_before_read: {database: {logs: 1, storage: 1, group_logs: 1}},
  reopened_readback: {...publicObservation.reopened_readback, reloaded_log: null}};
const unavailableResult = comparePublicCase(rustObservation, unavailable, nullSpec);
assert.equal(unavailableResult.saved_full_record_after_reopen_equal, false);
assert.equal(unavailableResult.reference_reloaded_log_unavailable, true);
assert.equal(unavailableResult.fields, null);
assert.notEqual(unavailableResult.fields_before_reopen, null);
assert.notDeepEqual(unavailableResult.saved_record_differences, []);
console.log('Public-service comparator: exact i64 boundaries, IEEE signed zero, list order, nested values, classifiers, source identity and unhidden date precision verified');
