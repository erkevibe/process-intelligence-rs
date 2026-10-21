import assert from 'node:assert/strict';
import fs from 'node:fs';
import {compareFilterCase} from '../tools/oracle/compare-core-filter.mjs';

// Synthetic adversarial observations, not claimed actual engine executions.
const corpus = JSON.parse(fs.readFileSync('fixtures/oracle-core-filter/corpus.json', 'utf8'));
const spec = corpus.cases.find(item => item.id === 'membership');
const input = JSON.parse(fs.readFileSync('fixtures/oracle-core-filter/membership.json', 'utf8'));
const selected = { ...input.source, cases: [input.source.cases[0], input.source.cases[2]] };
const common = {id: spec.id, input_sha256: spec.sha256, rule_literals: input.rule_literals,
  source_domain_before: structuredClone(input.source), selected_source_indices: [0,2], selected_source_log: structuredClone(selected)};
const java = {...common, status:'filtered', engine_invoked:true, engine_call_count:1,
  engine_identity:{class:'org.apromore.apmlog.filter.APMLogFilter',sha256:corpus.engine_class_sha256},
  predicate_identity:{sha256:'ce03abaddf3115810137685e11f453a5dfca72b2a1d569ed03b014c20f7dafc8'},
  parameters:corpus.parameters, source_domain_after:input.source,
  source_xlog_before:{typed:['synthetic']},source_xlog_after_conversion:{typed:['synthetic']},source_xlog_after_filter:{typed:['synthetic']},
  source_apm_before:{instances:['synthetic']},source_apm_after:{instances:['synthetic']}};
const rust = {...common,status:'ACTUAL_RUST_CASE_ACTIVITY_FILTER_OBSERVED',engine:'process_intelligence_rs::filters::apply',
  source_unchanged:true,source_before_sha256:'a'.repeat(64),source_after_sha256:'a'.repeat(64)};
assert.equal(compareFilterCase(rust,java,spec,input).overlap_fields_match,true);
const moved = structuredClone(rust); moved.selected_source_log.cases[0].events[0].ordinal = 0;
let report = compareFilterCase(moved,java,spec,input);
assert.equal(report.overlap_fields_match,false);
assert.equal(report.rust_selection_conservation.complete_selected_source_preserved,false);
assert(report.selected_full_log_differences.some(item => item.path.endsWith('.ordinal')));
const bothWrong = structuredClone(java); bothWrong.selected_source_log = moved.selected_source_log;
report = compareFilterCase(moved,bothWrong,spec,input);
assert.equal(report.selected_full_log_equal,true);
assert.equal(report.overlap_fields_match,false, 'matching mutations are not source conservation');
const reversedRust = structuredClone(rust), reversedJava = structuredClone(java);
for (const item of [reversedRust,reversedJava]) {item.selected_source_indices.reverse();item.selected_source_log.cases.reverse();}
report = compareFilterCase(reversedRust,reversedJava,spec,input);
assert.equal(report.selected_full_log_equal,true);
assert.equal(report.overlap_fields_match,false);
assert.equal(report.rust_selection_conservation.source_order_preserved,false);
const wrongRule = structuredClone(java);wrongRule.parameters.choice='REMOVE';
assert.throws(() => compareFilterCase(rust,wrongRule,spec,input),/agreed actual Java parameters/);
const stale = structuredClone(rust);stale.input_sha256='b'.repeat(64);
assert.throws(() => compareFilterCase(stale,java,spec,input),/frozen source SHA/);
const fake = structuredClone(java);fake.engine_identity.sha256='c'.repeat(64);
assert.throws(() => compareFilterCase(rust,fake,spec,input),/original engine class/);
const duplicate = structuredClone(rust);duplicate.selected_source_indices=[0,0];
assert.throws(() => compareFilterCase(duplicate,java,spec,input),/unique returned source indices/);
console.log('Core filter comparator: full source fields/order, matching mutations, sparse ordinals, class/rule/fixture identity guards verified.');
