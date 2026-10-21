// Observe genuine engines; this module never implements activity membership.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseObservation, fieldDifferences, sha256} from './compare-public-service.mjs';

const same = (left, right) => fieldDifferences(left, right).length === 0;
export function compareFilterCase(rust, java, spec, input) {
  assert.equal(input.schema_version, 1);
  assert.equal(input.id, spec.id);
  for (const observation of [rust, java]) {
    assert.equal(observation.id, spec.id, 'case identity');
    assert.equal(observation.input_sha256.toLowerCase(), spec.sha256.toLowerCase(), 'frozen source SHA');
    assert(same(observation.rule_literals, input.rule_literals), 'ordered actual rules');
    assert(same(observation.source_domain_before, input.source), 'complete actual source');
  }
  assert.equal(java.engine_identity.class, 'org.apromore.apmlog.filter.APMLogFilter');
  assert.equal(java.engine_identity.sha256.toLowerCase(), 'b07c241d7d5a430f9fd1f6cea5eb696a71eefdee7dc268ee0c81d18c464769b3', 'original engine class');
  assert.equal(java.predicate_identity.sha256.toLowerCase(), 'ce03abaddf3115810137685e11f453a5dfca72b2a1d569ed03b014c20f7dafc8', 'original predicate class');
  assert.equal(rust.status, 'ACTUAL_RUST_CASE_ACTIVITY_FILTER_OBSERVED');
  assert.equal(rust.engine, 'process_intelligence_rs::filters::apply');
  assert(same(java.parameters, {filter_type:'CASE_EVENT_ATTRIBUTE', choice:'RETAIN', inclusion:'ANY_VALUE',
    section:'CASE', key:'concept:name', rule_value_operation:'EQUAL', one_java_ordered_rule_list:true}), 'agreed actual Java parameters');
  const invoked = java.engine_invoked;
  assert.equal(typeof invoked, 'boolean');
  if (invoked) {assert.equal(java.status, 'filtered'); assert.equal(java.engine_call_count, 1, 'one whole-engine ordered-list call');}
  else assert.equal(java.status, 'converter_refused', 'not a filter-engine invocation');
  const javaState = {
    status: java.status, engine_invoked: invoked,
    selected_trace_indices: java.selected_source_indices ?? null,
    selected_source_case_ids: java.selected_source_log?.cases.map(item => item.id) ?? null,
    source_xlog_unchanged: same(java.source_xlog_before, java.source_xlog_after_conversion)
      && (!invoked || same(java.source_xlog_before, java.source_xlog_after_filter)),
    source_apm_unchanged: invoked ? same(java.source_apm_before, java.source_apm_after) : null,
  };
  if (java.exception) javaState.exception_class = java.exception.root.class;
  const rustState = {status: 'filtered', selected_source_case_ids: rust.selected_source_log.cases.map(item => item.id),
    source_unchanged: rust.source_unchanged && rust.source_before_sha256 === rust.source_after_sha256};
  const check = (expected, observed) => Object.fromEntries(Object.entries(expected).map(([key, value]) => {
    assert(Object.hasOwn(observed, key), 'known frozen hypothesis field'); return [key, same(value, observed[key])];
  }));
  const javaChecks = check(spec.expected_java, javaState), rustChecks = check(spec.expected_rust, rustState);
  const differences = invoked ? fieldDifferences(java.selected_source_log, rust.selected_source_log) : null;
  const indicesEqual = invoked ? same(java.selected_source_indices, rust.selected_source_indices) : null;
  const javaDomainUnchanged = same(java.source_domain_before, java.source_domain_after);
  const conservation = observation => {
    const indices = observation.selected_source_indices;
    assert(Array.isArray(indices) && indices.every(index => Number.isSafeInteger(index) && index >= 0 && index < input.source.cases.length), 'valid returned source indices');
    assert.equal(new Set(indices).size, indices.length, 'unique returned source indices');
    return {source_order_preserved: indices.every((index, position) => position === 0 || indices[position - 1] < index),
      complete_selected_source_preserved: same(observation.selected_source_log, {...input.source, cases: indices.map(index => input.source.cases[index])})};
  };
  const javaConservation = invoked ? conservation(java) : null, rustConservation = conservation(rust);
  return {id: spec.id, profile: spec.profile, input_sha256: spec.sha256,
    java: javaState, rust: rustState, java_domain_unchanged: javaDomainUnchanged,
    selected_full_log_equal: differences === null ? null : differences.length === 0,
    selected_full_log_differences: differences, source_indices_equal: indicesEqual,
    java_selection_conservation: javaConservation, rust_selection_conservation: rustConservation,
    original_manual_hypotheses: {java: spec.expected_java, rust: spec.expected_rust},
    hypothesis_checks: {java: javaChecks, rust: rustChecks},
    all_frozen_hypotheses_match: [...Object.values(javaChecks), ...Object.values(rustChecks)].every(Boolean),
    overlap_fields_match: spec.profile === 'overlap' ? differences?.length === 0 && indicesEqual
      && javaDomainUnchanged && javaState.source_xlog_unchanged && javaState.source_apm_unchanged && rustState.source_unchanged
      && Object.values(javaConservation).every(Boolean) && Object.values(rustConservation).every(Boolean) : null,
    diagnostic_difference_is_not_equality_pass: spec.profile !== 'overlap',
    scope: 'Full selected EventLog identities/order/fields and source conservation; rich XLog and APM source conservation observed separately, no whole Core/R5 claim'};
}

function main() {
  assert.equal(process.argv.length, 5, 'Java index, Rust index, NEW report JSON');
  const read = file => {assert(fs.statSync(file).size <= 4 * 1024 * 1024, 'bounded JSON'); return fs.readFileSync(file);};
  const checked = (file, digest) => {const bytes = read(file); assert.equal(sha256(bytes), digest.toLowerCase(), 'actual bytes SHA'); return parseObservation(bytes.toString('utf8'));};
  const javaBytes = read(process.argv[2]), rustBytes = read(process.argv[3]);
  const javaIndex = parseObservation(javaBytes.toString('utf8')), rustIndex = parseObservation(rustBytes.toString('utf8'));
  const corpusPath = 'fixtures/oracle-core-filter/corpus.json', corpusBytes = read(corpusPath);
  const corpus = parseObservation(corpusBytes.toString('utf8'));
  assert.equal(sha256(corpusBytes), javaIndex.corpus_sha256.toLowerCase());
  assert.equal(sha256(corpusBytes), rustIndex.corpus_sha256.toLowerCase());
  assert.equal(corpus.cases.length, 8);
  const index = rows => {
    assert.equal(rows.length, corpus.cases.length, 'complete actual corpus');
    const result = new Map(rows.map(row => [row.id, row])); assert.equal(result.size, rows.length, 'unique case ids'); return result;
  };
  const javaCases = index(javaIndex.cases), rustCases = index(rustIndex.cases);
  const cases = corpus.cases.map(spec => {
    const javaRow = javaCases.get(spec.id), rustRow = rustCases.get(spec.id); assert(javaRow && rustRow, 'known actual cases');
    const input = checked(path.join(path.dirname(corpusPath), spec.file), spec.sha256);
    return {...compareFilterCase(checked(rustRow.observation_path, rustRow.observation_sha256),
      checked(javaRow.observation_path, javaRow.observation_sha256), spec, input),
      java_observation_sha256: javaRow.observation_sha256, rust_observation_sha256: rustRow.observation_sha256};
  });
  const report = {schema_version: 1, status: 'ACTUAL_CORE_FILTER_FIELD_COMPARISON_COMPLETED',
    corpus_sha256: sha256(corpusBytes), java_index_sha256: sha256(javaBytes), rust_index_sha256: sha256(rustBytes),
    case_count: cases.length, cases, no_whole_R5_or_Core_parity_claim: true};
  fs.writeFileSync(process.argv[4], JSON.stringify(report, null, 2) + '\n', {flag: 'wx'});
  console.log(JSON.stringify({status: report.status, case_count: cases.length}));
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
