// Own observer comparator, never an implementation of the legacy importer.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const MAX_BYTES = 4 * 1024 * 1024;
const missing = Symbol('missing');
export const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

// JSON.parse alone rounds distinct XES i64 values to the same JS Number.
// Node24's original numeric token is required BEFORE this precision is lost.
export function parseObservation(text) {
  assert(Buffer.byteLength(text) <= MAX_BYTES, 'observation byte cap');
  return JSON.parse(text.replace(/^\uFEFF/, ''), (_key, value, context) => {
    if (typeof value !== 'number') return value;
    assert(context && typeof context.source === 'string', 'numeric source tokens required');
    return /^-?(0|[1-9]\d*)$/.test(context.source) && !Number.isSafeInteger(value)
      ? BigInt(context.source) : value;
  });
}

function integer(value) {
  if (typeof value === 'bigint') return value.toString();
  assert(typeof value === 'number' && Number.isSafeInteger(value), 'exact integer required');
  return String(value);
}
function floating(value) {
  // An integer-looking JSON token may belong to an XES double. Rounding is
  // correct ONLY in this typed branch; XES i64 values remain decimal strings.
  if (typeof value === 'bigint') value = Number(value);
  assert(typeof value === 'number' && Number.isFinite(value), 'finite observed float required');
  const buffer = Buffer.alloc(8);
  buffer.writeDoubleBE(value);
  return {ieee754_binary64: buffer.toString('hex')};
}
function date(value, side) {
  if (side === 'java') return {epoch_milliseconds: integer(value), sub_millisecond_ns: '000000'};
  assert(typeof value === 'string', 'observed RFC3339 date required');
  const milliseconds = Date.parse(value);
  assert(Number.isSafeInteger(milliseconds), 'valid observed date');
  const fraction = /T\d\d:\d\d:\d\d(?:\.(\d+))?(?:Z|[+-]\d\d:\d\d)$/.exec(value);
  assert(fraction && (fraction[1]?.length ?? 0) <= 9, 'bounded observed date precision');
  return {epoch_milliseconds: String(milliseconds), sub_millisecond_ns: (fraction[1] ?? '').padEnd(9, '0').slice(3)};
}
const ordered = attributes => [...attributes].sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0);

export function typedAttribute(attribute, side, depth = 0) {
  assert(depth <= 32, 'attribute depth cap');
  assert(side === 'java' || side === 'rust', 'named observation side');
  assert(typeof attribute.key === 'string', 'attribute key');
  const type = side === 'java' ? attribute.type : attribute.value.type.toLowerCase();
  let value = side === 'java' ? attribute.value : attribute.value.content;
  if (type === 'int') value = integer(value);
  else if (type === 'float') value = floating(value);
  else if (type === 'date') value = date(value, side);
  else if (type === 'list' || type === 'container') {
    assert(Array.isArray(value) && value.length <= 10000, 'attribute collection cap');
    value = value.map(child => typedAttribute(child, side, depth + 1));
    if (type === 'container') value = ordered(value);
  } else if (type === 'boolean') assert(typeof value === 'boolean', 'boolean type');
  else {
    assert(type === 'string' || type === 'id', 'known observed attribute type');
    assert(typeof value === 'string', 'textual attribute type');
  }
  const result = {key: attribute.key, type, value};
  const children = side === 'java' ? attribute.children : attribute.own_attributes;
  if (children?.length) result.children = ordered(children.map(child => typedAttribute(child, side, depth + 1)));
  return result;
}

export function typedLog(log, side) {
  assert(side === 'java' || side === 'rust', 'named observation side');
  const attributes = values => ordered((values ?? []).map(attribute => typedAttribute(attribute, side)));
  assert(Array.isArray(log.traces), 'observed traces');
  return {
    attributes: attributes(log.attributes),
    classifiers: log.classifiers ?? [],
    extensions: [...(log.extensions ?? [])].sort((a, b) => a.uri < b.uri ? -1 : a.uri > b.uri ? 1 : 0),
    global_trace_attributes: attributes(log[side === 'java' ? 'global_trace_attributes' : 'global_trace_attrs']),
    global_event_attributes: attributes(log[side === 'java' ? 'global_event_attributes' : 'global_event_attrs']),
    traces: log.traces.map(trace => ({attributes: attributes(trace.attributes),
      events: trace.events.map(event => ({attributes: attributes(event.attributes)}))})),
  };
}

export function fieldDifferences(left, right, location = '$', out = []) {
  if (Object.is(left, right)) return out;
  assert(out.length < 512, 'difference cap; no partial comparison PASS');
  if (Array.isArray(left) && Array.isArray(right)) {
    if (left.length !== right.length) out.push({path: `${location}.length`, left: left.length, right: right.length});
    for (let i = 0; i < Math.max(left.length, right.length); i++) {
      fieldDifferences(i < left.length ? left[i] : missing, i < right.length ? right[i] : missing, `${location}[${i}]`, out);
    }
  } else if (Array.isArray(left) === Array.isArray(right) && left !== null && right !== null && typeof left === 'object' && typeof right === 'object') {
    for (const key of [...new Set([...Object.keys(left), ...Object.keys(right)])].sort()) {
      fieldDifferences(Object.hasOwn(left, key) ? left[key] : missing, Object.hasOwn(right, key) ? right[key] : missing, `${location}.${key}`, out);
    }
  } else out.push({path: location, left: left === missing ? null : left, right: right === missing ? null : right,
    left_missing: left === missing, right_missing: right === missing});
  return out;
}

export function retainedSourceMetadata(raw, preview) {
  const result = typedLog(raw, 'rust');
  const usedCases = new Set();
  result.traces = preview.log.cases.map(trace => {
    assert(/^case-\d+$/.test(trace.id), 'actual Rust source case identity');
    const index = Number(trace.id.slice(5));
    assert(Number.isSafeInteger(index) && raw.traces[index] && !usedCases.has(index), 'unique existing source case');
    usedCases.add(index);
    const usedEvents = new Set();
    const sourceTrace = resultSource(raw.traces[index]);
    return {attributes: sourceTrace.attributes, events: trace.events.map(event => {
      assert(Number.isSafeInteger(event.ordinal) && event.ordinal >= 0 && sourceTrace.events[event.ordinal] && !usedEvents.has(event.ordinal), 'unique existing source event');
      usedEvents.add(event.ordinal);
      const attributes = [...sourceTrace.events[event.ordinal].attributes];
      if (preview.changes.some(change => change.action === 'default_lifecycle' && change.case_index === index && change.event_index === event.ordinal)) {
        assert(!attributes.some(attribute => attribute.key === 'lifecycle:transition'), 'default absent lifecycle only');
        attributes.push({key: 'lifecycle:transition', type: 'string', value: 'complete'});
      }
      return {attributes: ordered(attributes)};
    })};
  });
  return result;
}
function resultSource(trace) {
  return typedLog({attributes: [], traces: [trace]}, 'rust').traces[0];
}

function millisecondsOnly(value) {
  if (Array.isArray(value)) return value.map(millisecondsOnly);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, key === 'sub_millisecond_ns' ? '000000' : millisecondsOnly(child)]));
  }
  return value;
}

const get = (attributes, key) => attributes.find(attribute => attribute.key === key)?.value ?? null;
function savedCore(log) {
  return {name: get(log.attributes, 'concept:name'), cases: log.traces.map(trace => ({
    name: get(trace.attributes, 'concept:name'), events: trace.events.map(event => ({
      activity: get(event.attributes, 'concept:name'), lifecycle: get(event.attributes, 'lifecycle:transition'),
      timestamp: get(event.attributes, 'time:timestamp'),
    })),
  }))};
}
function previewCore(log) {
  return {name: log.name, cases: log.cases.map(trace => ({name: trace.name,
    events: trace.events.map(event => ({activity: event.activity, lifecycle: event.lifecycle,
      timestamp: event.timestamp === null ? null : date(event.timestamp, 'rust')})),
  }))};
}

export function compareSavedLogs(raw, preview, javaSavedLog) {
  const retained = retainedSourceMetadata(raw, preview);
  const saved = typedLog(javaSavedLog, 'java');
  const exact = fieldDifferences(retained, saved);
  const core = previewCore(preview.log), legacyCore = savedCore(saved);
  return {retained_metadata_exact: exact.length === 0, exact_field_differences: exact,
    field_differences_at_declared_millisecond_resolution: fieldDifferences(millisecondsOnly(retained), saved),
    product_core_field_differences: fieldDifferences(core, legacyCore),
    product_core_differences_at_declared_millisecond_resolution: fieldDifferences(millisecondsOnly(core), legacyCore),
    product_projection_report: preview.projection_report ?? null,
    precision_normalization_is_not_exact_equality: true,
    scope: 'Full source metadata of retained Rust identities after observed lifecycle defaults versus actual saved Java log; not metadata retention in the Rust analysis projection'};
}

function assertPublicObservation(rust, observation) {
  assert(/^[a-f0-9]{64}$/i.test(rust.input_sha256), 'actual fixture digest required');
  assert.equal(rust.input_sha256.toLowerCase(), observation.input_sha256?.toLowerCase(), 'same actual fixture');
  assert.equal(observation.service_identity?.sha256?.toLowerCase(), '24900e3f31629f3337490b930d51fbe7b4c1436872ed184477ae580a17d61097', 'original service class pin');
  assert.equal(observation.proxy?.is_aop_proxy, true, 'actual Spring proxy');
  assert.equal(observation.proxy.target_class, 'org.apromore.service.impl.EventLogServiceImpl');
  assert(observation.proxy.advice.some(name => name.endsWith('TransactionInterceptor')), 'actual transaction advice');
  assert(observation.transaction_entries?.length > 0 && observation.transaction_entries.every(entry => entry.actual_transaction_active === true), 'observed active transaction');
}
function savedRecordDifferences(before, after) {
  const persisted = saved => {
    const {reloaded_log, apm_cache_class: _ephemeral, ...record} = saved;
    assert(reloaded_log !== undefined, 'explicit typed readback or null required');
    return {...record, reloaded_log: reloaded_log === null ? null : typedLog(reloaded_log, 'java')};
  };
  return fieldDifferences(persisted(before), persisted(after));
}

export function compareMinimalPublic(rust, observation) {
  assertPublicObservation(rust, observation);
  assert.equal(observation.status, 'ACTUAL_PUBLIC_MINIMAL_GATE_COMPLETED', 'actual successful public gate');
  const before = observation.first_readback;
  const after = observation.reopened_readback;
  const restart = savedRecordDifferences(before, after);
  return {schema_version: 1, status: 'ACTUAL_PUBLIC_GATE_FIELD_COMPARISON_COMPLETED', input_sha256: rust.input_sha256,
    rust_admission: rust.preview.status, rust_error: rust.preview.error?.code ?? null,
    saved_full_record_after_reopen_equal: restart.length === 0, saved_record_differences: restart,
    ephemeral_apm_cache_classes: [before.apm_cache_class, after.apm_cache_class],
    fields: rust.preview.status === 'ok' && after.reloaded_log !== null ? compareSavedLogs(rust.raw_rust4pm.log, rust.preview.value, after.reloaded_log) : null,
    reference_reloaded_log_unavailable: after.reloaded_log === null,
    rejected_rust_input_is_not_parity: rust.preview.status !== 'ok', no_full_R2_or_service_parity_claim: true};
}

// Snapshot deltas are observations, not a replacement implementation of the
// service. In particular, an outer DB rollback does not imply zero file/cache
// changes. Source-derived manual hypotheses are evaluated separately.
export function comparePublicCase(rust, observation, frozenSpec) {
  assertPublicObservation(rust, observation);
  assert.equal(observation.status, 'ACTUAL_PUBLIC_CASE_OBSERVED', 'actual public case');
  assert.equal(observation.id, frozenSpec.id, 'frozen case identity');
  assert.equal(observation.input_sha256.toLowerCase(), frozenSpec.sha256.toLowerCase(), 'frozen source identity');
  assert.deepEqual(fieldDifferences(observation.parameters, frozenSpec), [], 'unchanged frozen parameters');
  const delta = {};
  for (const name of ['logs', 'storage', 'group_logs']) {
    assert(Number.isSafeInteger(observation.before.database[name]) && Number.isSafeInteger(observation.after.database[name]), 'observed DB count');
    delta[name] = observation.after.database[name] - observation.before.database[name];
  }
  delta.files = observation.after.files.length - observation.before.files.length;
  delta.cache_entries = observation.after.cache.length - observation.before.cache.length;
  const success = observation.outcome === 'success';
  const restart = success ? savedRecordDifferences(observation.first_readback, observation.reopened_readback) : null;
  const result = {schema_version: 1, status: 'ACTUAL_PUBLIC_CASE_FIELD_COMPARISON_COMPLETED', id: observation.id,
    input_sha256: observation.input_sha256, reference_outcome: observation.outcome,
    original_source_hypothesis: frozenSpec.expected_source_hypothesis,
    rust_preview_status: rust.preview.status, rust_preview_error: rust.preview.error?.code ?? null,
    rust_preview_is_not_public_service_auth_or_persistence: true,
    rust_fully_filtered: rust.preview.status === 'ok' ? rust.preview.value.fully_filtered : null,
    actual_state_delta: delta,
    files_before_after_differences: fieldDifferences(observation.before.files, observation.after.files),
    cache_before_after_differences: fieldDifferences(observation.before.cache, observation.after.cache),
    database_after_vs_reopen: fieldDifferences(observation.after.database, observation.reopened_before_read.database),
    saved_full_record_after_reopen_equal: restart === null ? null : restart.length === 0,
    saved_record_differences: restart,
    reference_reloaded_log_unavailable: success ? observation.reopened_readback.reloaded_log === null : null,
    fields_before_reopen: success && rust.preview.status === 'ok' && observation.first_readback.reloaded_log !== null
      ? compareSavedLogs(rust.raw_rust4pm.log, rust.preview.value, observation.first_readback.reloaded_log) : null,
    fields: success && rust.preview.status === 'ok' && observation.reopened_readback.reloaded_log !== null
      ? compareSavedLogs(rust.raw_rust4pm.log, rust.preview.value, observation.reopened_readback.reloaded_log) : null,
    no_full_R2_or_service_parity_claim: true};
  // Never stringify a root exception stack/message into the public report.
  if (observation.exception) result.actual_root_exception_class = observation.exception.root.class;
  return result;
}

function main() {
  if (process.argv[2] === '--matrix') {
    assert.equal(process.argv.length, 6, 'reference index, Rust index, NEW output JSON');
    const read = file => {assert(fs.statSync(file).size <= MAX_BYTES, 'input cap'); return fs.readFileSync(file);};
    const checked = (file, expected) => {const bytes = read(file); assert.equal(sha256(bytes), expected.toLowerCase(), 'input SHA256'); return parseObservation(bytes.toString('utf8'));};
    const referenceBytes = read(process.argv[3]), rustBytes = read(process.argv[4]);
    const reference = parseObservation(referenceBytes.toString('utf8')), rustIndex = parseObservation(rustBytes.toString('utf8'));
    const specs = new Map();
    for (const file of ['fixtures/oracle-public-service/corpus.json', 'fixtures/oracle-public-service/supplement-flat/corpus.json']) {
      const bytes = read(file), corpus = parseObservation(bytes.toString('utf8'));
      for (const spec of corpus.corpus) {
        assert(!specs.has(spec.id), 'unique frozen case');
        assert.equal(sha256(read(path.join(path.dirname(file), spec.file))), spec.sha256.toLowerCase(), 'frozen fixture SHA256');
        specs.set(spec.id, {spec, corpusHash: sha256(bytes)});
      }
    }
    const rustByHash = new Map();
    for (const row of rustIndex.cases) {
      assert.equal(row.program_sha256.toLowerCase(), '906a06c95a87013fce481ff3ec23054bada9e5a9b5d81aaf8b5895527a5a1969');
      assert(!rustByHash.has(row.input_sha256), 'unique Rust source');
      rustByHash.set(row.input_sha256, checked(row.path, row.observation_sha256));
    }
    assert.equal(reference.cases.length, specs.size, 'complete frozen corpus');
    const seen = new Set();
    const cases = reference.cases.map(row => {
      assert(!seen.has(row.id), 'unique reference case'); seen.add(row.id);
      const {spec, corpusHash} = specs.get(row.id) ?? {};
      assert(spec, 'known frozen case');
      const observation = checked(row.native.path + '.json', row.observation_sha256);
      assert.equal(observation.corpus_sha256, corpusHash, 'frozen corpus identity');
      const rust = rustByHash.get(spec.sha256.toLowerCase()); assert(rust, 'actual Rust observation');
      return {...comparePublicCase(rust, observation, spec),
        reference_observation_sha256: row.observation_sha256,
        adapter_generation: row.adapter_generation,
        frozen_manual_expected_checks: row.frozen_manual_expected_checks,
        pending_manual_expected_fields: row.pending_manual_expected_fields};
    });
    const report = {schema_version: 1, status: 'ACTUAL_PUBLIC_CORPUS_FIELD_COMPARISON_COMPLETED',
      reference_index_sha256: sha256(referenceBytes), rust_index_sha256: sha256(rustBytes),
      case_count: cases.length, source_aware_carry: reference.source_aware_carry,
      all_reference_manual_hypotheses_match: reference.all_frozen_checked_fields_match,
      cases, no_full_R2_or_service_parity_claim: true};
    fs.writeFileSync(process.argv[5], JSON.stringify(report, (_key, value) => typeof value === 'bigint' ? value.toString() : value, 2) + '\n', {flag: 'wx'});
    console.log(JSON.stringify({status: report.status, case_count: cases.length}));
    return;
  }
  assert.equal(process.argv.length, 5, 'Rust observation, public minimal observation, NEW output JSON');
  const [rustPath, javaPath, output] = process.argv.slice(2);
  const read = file => {assert(fs.statSync(file).size <= MAX_BYTES, 'input cap'); return fs.readFileSync(file);};
  const rustBytes = read(rustPath), javaBytes = read(javaPath);
  const report = compareMinimalPublic(parseObservation(rustBytes.toString('utf8')), parseObservation(javaBytes.toString('utf8')));
  report.rust_observation_sha256 = sha256(rustBytes);
  report.public_observation_sha256 = sha256(javaBytes);
  fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n', {flag: 'wx'});
  console.log(JSON.stringify({status: report.status, rust_admission: report.rust_admission, reopened_equal: report.saved_full_record_after_reopen_equal}));
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
