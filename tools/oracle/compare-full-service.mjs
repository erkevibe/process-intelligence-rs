import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const json = file => {
  assert(fs.statSync(file).size <= 4 * 1024 * 1024, 'JSON input cap');
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
};
const orderedAttributes = values => [...values].sort((a, b) => a.key.localeCompare(b.key, 'en'));

export function rustAttribute(attribute) {
  const type = attribute.value.type.toLowerCase();
  let value = attribute.value.content;
  if (type === 'date') {
    value = Date.parse(value);
    assert(Number.isFinite(value), 'invalid observed Rust date');
  } else if (type === 'container' || type === 'list') {
    value = value.map(rustAttribute);
    if (type === 'container') value = orderedAttributes(value);
  }
  const result = {key: attribute.key, type, value: value ?? null};
  if (attribute.own_attributes?.length) result.children = orderedAttributes(attribute.own_attributes.map(rustAttribute));
  return result;
}

export function javaAttribute(attribute) {
  const result = {key: attribute.key, type: attribute.type, value: attribute.value};
  if (attribute.type === 'container' || attribute.type === 'list') {
    result.value = attribute.value.map(javaAttribute);
    if (attribute.type === 'container') result.value = orderedAttributes(result.value);
  }
  if (attribute.children?.length) result.children = orderedAttributes(attribute.children.map(javaAttribute));
  return result;
}

function normalizedLog(log, attribute, traceGlobals, eventGlobals) {
  return {
    attributes: orderedAttributes(log.attributes.map(attribute)),
    classifiers: log.classifiers ?? [],
    extensions: [...(log.extensions ?? [])].sort((a, b) => a.uri.localeCompare(b.uri, 'en')),
    global_trace_attributes: orderedAttributes((log[traceGlobals] ?? []).map(attribute)),
    global_event_attributes: orderedAttributes((log[eventGlobals] ?? []).map(attribute)),
    traces: log.traces.map(trace => ({
      attributes: orderedAttributes(trace.attributes.map(attribute)),
      events: trace.events.map(event => ({attributes: orderedAttributes(event.attributes.map(attribute))})),
    })),
  };
}
export const rustLog = log => normalizedLog(log, rustAttribute, 'global_trace_attrs', 'global_event_attrs');
export const javaLog = log => normalizedLog(log, javaAttribute, 'global_trace_attributes', 'global_event_attributes');

export function differences(left, right, location = '$', output = []) {
  if (Object.is(left, right)) return output;
  assert(output.length < 256, 'field difference cap');
  if (Array.isArray(left) && Array.isArray(right)) {
    if (left.length !== right.length) output.push({path: location + '.length', left: left.length, right: right.length});
    for (let i = 0; i < Math.max(left.length, right.length); i++) differences(left[i], right[i], `${location}[${i}]`, output);
  } else if (left && right && typeof left === 'object' && typeof right === 'object') {
    for (const key of [...new Set([...Object.keys(left), ...Object.keys(right)])].sort()) differences(left[key], right[key], location + '.' + key, output);
  } else {
    output.push({path: location, left: left ?? null, right: right ?? null});
  }
  return output;
}

const attr = (attributes, key) => attributes.find(a => a.key === key);
export function coreProjection(log) {
  return {
    name: attr(log.attributes, 'concept:name')?.value ?? null,
    cases: log.traces.map(trace => ({
      name: attr(trace.attributes, 'concept:name')?.value ?? null,
      events: trace.events.map(event => ({
        activity: attr(event.attributes, 'concept:name')?.value ?? null,
        lifecycle: attr(event.attributes, 'lifecycle:transition')?.value ?? null,
        timestamp_millis: attr(event.attributes, 'time:timestamp')?.value ?? null,
      })),
    })),
  };
}
export function previewProjection(preview) {
  return {
    name: preview.log.name,
    cases: preview.log.cases.map(trace => ({
      name: trace.name,
      events: trace.events.map(event => ({
        activity: event.activity,
        lifecycle: event.lifecycle,
        timestamp_millis: event.timestamp === null ? null : Date.parse(event.timestamp),
      })),
    })),
  };
}

// This checks conservation against actual source/Rust identities. It is not a
// substitute implementation of the legacy importer or an independent oracle.
function retainedSourceMetadata(raw, preview) {
  const result = rustLog(raw);
  result.traces = preview.log.cases.map(trace => {
    assert(/^case-\d+$/.test(trace.id), 'actual Rust case identity');
    const index = Number(trace.id.slice(5));
    assert(raw.traces[index], 'source case exists');
    return {
      attributes: orderedAttributes(raw.traces[index].attributes.map(rustAttribute)),
      events: trace.events.map(event => {
        const source = raw.traces[index].events[event.ordinal];
        assert(source, 'actual source ordinal exists');
        const attributes = source.attributes.map(rustAttribute);
        const defaulted = preview.changes.some(change => change.action === 'default_lifecycle' && change.case_index === index && change.event_index === event.ordinal);
        if (defaulted) {
          assert(!attr(attributes, 'lifecycle:transition'));
          attributes.push({key: 'lifecycle:transition', type: 'string', value: 'complete'});
        }
        return {attributes: orderedAttributes(attributes)};
      }),
    };
  });
  return result;
}

function precisionDifferences(preview, legacy) {
  const out = [];
  preview.log.cases.forEach((trace, ti) => trace.events.forEach((event, ei) => {
    const fraction = /\.(\d+)/.exec(event.timestamp ?? '')?.[1] ?? '';
    if (/[1-9]/.test(fraction.slice(3))) out.push({rust_case_id: trace.id, rust_event_ordinal: event.ordinal, rust_timestamp: event.timestamp, java_millis: legacy.cases[ti].events[ei].timestamp_millis});
  }));
  return out;
}

export function compareAccepted(raw, preview, observation, id) {
  const legacyRich = javaLog(observation.log);
  const legacyCore = coreProjection(legacyRich);
  const rustCore = previewProjection(preview);
  const coreDifferences = differences(rustCore, legacyCore);
  if (id === 'default-log-name') {
    assert.equal(rustCore.name, null);
    assert.equal(legacyCore.name, 'Anonymous log imported from ');
    assert.deepEqual(coreDifferences, [{path: '$.name', left: null, right: 'Anonymous log imported from '}]);
  } else assert.deepEqual(coreDifferences, [], `unexpected core fields: ${id}`);
  const conserved = retainedSourceMetadata(raw, preview);
  const metadataBeforeDeclaredDefault = differences(conserved, legacyRich);
  if (id === 'default-log-name') {
    conserved.attributes.push({key: 'concept:name', type: 'string', value: 'Anonymous log imported from '});
    conserved.attributes = orderedAttributes(conserved.attributes);
  }
  assert.deepEqual(differences(conserved, legacyRich), [], `retained full metadata differs: ${id}`);
  const precision = precisionDifferences(preview, legacyCore);
  assert.equal(precision.length, id === 'submillisecond' ? 1 : 0, `undeclared precision difference: ${id}`);
  return {
    core_field_differences: coreDifferences,
    retained_source_full_metadata_differences_before_declared_default: metadataBeforeDeclaredDefault,
    retained_source_metadata_except_declared_default: 'equal',
    timestamp_precision_differences: precision,
    product_projection_report: preview.projection_report,
    source_identity_scope: 'Only Rust source case IDs/ordinals are claimed; Java after-import arrays do not invent original object indices',
  };
}

async function main() {
  const [exeInput, corpusInput, referenceInput, outputInput] = process.argv.slice(2);
  assert(exeInput && corpusInput && referenceInput && outputInput, 'EXE CORPUS REFERENCE_DIR NEW_PRIVATE_OUT required');
  const exe = fs.realpathSync(exeInput), corpusDir = fs.realpathSync(corpusInput), referenceDir = fs.realpathSync(referenceInput);
  const out = path.resolve(outputInput), allowed = path.resolve('.local/sprint16/root') + path.sep;
  assert(out.toLowerCase().startsWith(allowed.toLowerCase()) && !fs.existsSync(out), 'new private S16 Root output');
  const corpusFile = path.join(corpusDir, 'corpus.json'), contractFile = path.join(corpusDir, 'rust-comparison-contract.json');
  const corpus = json(corpusFile), contract = json(contractFile), referenceFile = path.join(referenceDir, 'reference-results.json');
  const reference = json(referenceFile), referenceHash = sha(fs.readFileSync(referenceFile));
  assert.equal(sha(fs.readFileSync(contractFile)), '512572453bf402617709168885003568408aa12311f8518a6d680989030b0d07');
  assert.equal(sha(fs.readFileSync(corpusFile)), contract.corpus_sha256);
  assert.equal(reference.corpus_sha256.toLowerCase(), contract.corpus_sha256);
  assert.equal(corpus.corpus.length, 20); assert.equal(contract.rows.length, 20); assert.equal(reference.cases.length, 20);
  assert.equal(new Set(reference.cases.map(c => c.id)).size, 20);
  const exeHash = sha(fs.readFileSync(exe)), comparatorHash = sha(fs.readFileSync(fileURLToPath(import.meta.url)));
  fs.mkdirSync(out);
  const results = [];
  for (const fixture of corpus.corpus) {
    assert(Date.now() < Date.parse('2026-10-20T19:46:17Z'), 'sprint runtime freeze');
    const input = path.join(corpusDir, fixture.file), expected = contract.rows.find(r => r.id === fixture.id);
    assert(expected); assert.equal(sha(fs.readFileSync(input)), fixture.sha256); assert.equal(expected.input_sha256, fixture.sha256);
    const legacyFile = path.join(referenceDir, fixture.id + '.json'), legacyBytes = fs.readFileSync(legacyFile), legacy = json(legacyFile);
    const refCase = reference.cases.find(c => c.id === fixture.id);
    const failedManualChecks = Object.entries(refCase.manual_expected_checks).filter(([, value]) => value !== true).map(([key]) => key);
    assert.equal(sha(legacyBytes), refCase.observation_sha256.toLowerCase());
    assert.equal(legacy.input_sha256, fixture.sha256); assert.equal(legacy.selected_path, 'unchanged_full_class.private.importFromStream');
    assert.equal(legacy.service_class_sha256, '24900e3f31629f3337490b930d51fbe7b4c1436872ed184477ae580a17d61097');
    assert.equal(legacy.factory, 'org.deckfour.xes.factory.XFactoryNaiveImpl');
    assert.equal(legacy.extension, fixture.extension);
    assert.equal(legacy.public_importLog_executed, false); assert.equal(legacy.assertions_enabled, false);
    assert.equal(refCase.native.native_exit, 0); assert.equal(legacy.stream.adapter_rewind, false);
    assert.equal(sha(fs.readFileSync(exe)), exeHash);
    const run = spawnSync(exe, ['--trusted-corpus', input], {encoding: 'utf8', windowsHide: true, timeout: 15000, maxBuffer: 4 * 1024 * 1024});
    const stdout = Buffer.from(run.stdout ?? ''), stderr = Buffer.from(run.stderr ?? '');
    fs.writeFileSync(path.join(out, fixture.id + '.stdout'), stdout, {flag: 'wx'});
    fs.writeFileSync(path.join(out, fixture.id + '.stderr'), stderr, {flag: 'wx'});
    const native = {native_exit: run.status, signal: run.signal, launch_error: run.error?.code ?? null, stdout_bytes: stdout.length, stderr_bytes: stderr.length, stdout_sha256: sha(stdout), stderr_sha256: sha(stderr), complete_eof: run.status === 0 && !run.error};
    fs.writeFileSync(path.join(out, fixture.id + '.native.json'), JSON.stringify(native, null, 2), {flag: 'wx'});
    assert.equal(run.status, 0); assert(!run.error);
    const rust = JSON.parse(stdout.toString('utf8').replace(/^\uFEFF/, ''));
    assert.equal(rust.input_sha256, fixture.sha256); assert.equal(rust.preview.status, expected.rust_preview_status);
    if (expected.rust_error) assert.equal(rust.preview.error.code, expected.rust_error);
    let fields = null;
    if (rust.preview.status === 'ok' && legacy.status === 'success') {
      assert.equal(rust.raw_rust4pm.status, 'ok');
      fields = compareAccepted(rust.raw_rust4pm.log, rust.preview.value, legacy, fixture.id);
      const loss = contract.manual_projection_losses[fixture.id];
      if (loss) {
        const actual = rust.preview.value.projection_report;
        assert.deepEqual([actual.omitted_log_attributes, actual.omitted_trace_attributes, actual.omitted_event_attributes, actual.ignored_classifiers], [loss.log, loss.trace, loss.event, loss.classifiers]);
        if ('extensions' in loss) assert.equal(actual.omitted_extension_declarations, loss.extensions);
      }
    } else assert(expected.allowed_service_difference || failedManualChecks.length > 0, 'undeclared outcome divergence without preserved failing hypothesis');
    results.push({id: fixture.id, input_sha256: fixture.sha256, selected_reference_path: legacy.selected_path, reference_status: legacy.status, rust_preview_status: rust.preview.status, rust_error: rust.preview.error?.code ?? null, declared_difference: expected.allowed_service_difference, original_manual_expected_service: fixture.expected_service, actual_manual_expected_checks: refCase.manual_expected_checks, failed_original_manual_checks: failedManualChecks, unexpected_outcome_not_predeclared: !expected.allowed_service_difference && failedManualChecks.length > 0, fields, native, reference_observation_sha256: sha(legacyBytes)});
    assert.equal(sha(fs.readFileSync(input)), fixture.sha256);
  }
  assert.equal(sha(fs.readFileSync(exe)), exeHash); assert.equal(sha(fs.readFileSync(referenceFile)), referenceHash);
  assert.equal(sha(fs.readFileSync(fileURLToPath(import.meta.url))), comparatorHash);
  const unexpectedRows = results.filter(r => r.failed_original_manual_checks.length > 0).map(r => r.id);
  const report = {schema_version: 1, status: unexpectedRows.length ? 'FINITE_FIELDWISE_COMPARISON_COMPLETED_WITH_UPSTREAM_EXPECTATION_DIFFERENCES' : 'FINITE_FIELDWISE_COMPARISON_COMPLETED', original_manual_expectation_mismatch_rows: unexpectedRows, no_original_expectations_rewritten: true, corpus_sha256: contract.corpus_sha256, contract_sha256: sha(fs.readFileSync(contractFile)), reference_report_sha256: referenceHash, observer_exe_sha256: exeHash, comparator_sha256: comparatorHash, results, no_full_service_parity_claim: true, no_public_authenticated_importLog_claim: true};
  fs.writeFileSync(path.join(out, 'comparison.json'), JSON.stringify(report, null, 2), {flag: 'wx'});
  console.log(JSON.stringify({status: report.status, cases: results.length, accepted_fieldwise: results.filter(r => r.fields).length, explicit_differences: results.filter(r => r.declared_difference).length, original_manual_expectation_mismatch_rows: unexpectedRows}));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(error => {console.error(error.stack); process.exitCode = 1;});
