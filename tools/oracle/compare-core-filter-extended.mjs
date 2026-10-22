// Pure comparison of actual whole-engine outputs; no activity predicate here.
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {assert,same,fieldDifferences,fieldChecks,all,runCorpus} from './compare-core-reference-support.mjs';
function conservation(observation,input) {
  if(observation.selected_source_log===null||observation.selected_source_log===undefined) return null;
  const indices=observation.selected_source_indices,positions=observation.selected_event_positions;
  assert(Array.isArray(indices)&&Array.isArray(positions)&&indices.length===positions.length,'actual trace/event source positions');
  assert.equal(new Set(indices).size,indices.length,'unique source traces');
  const cases=indices.map((index,i)=>{
    assert(Number.isSafeInteger(index)&&index>=0&&index<input.source.cases.length,'actual source trace bound');
    const source=input.source.cases[index],events=positions[i];
    assert(Array.isArray(events)&&new Set(events).size===events.length,'actual unique source event positions');
    for(const n of events) assert(Number.isSafeInteger(n)&&n>=0&&n<source.events.length,'actual source event bound');
    return {...source,events:events.map(n=>source.events[n])};
  });
  return {source_trace_order_preserved:indices.every((n,i)=>i===0||indices[i-1]<n),source_event_order_preserved:positions.every(events=>events.every((n,i)=>i===0||events[i-1]<n)),complete_selected_fields_preserved:same(observation.selected_source_log,{...input.source,cases})};
}
function rulesProjection(rules) {
  assert(Array.isArray(rules)&&rules.length<=3,'bounded actual ordered rules');
  return rules.map(rule=>{
    assert.equal(rule.inclusion,'ANY_VALUE','actual selected inclusion');
    assert.equal(rule.key,rule.filter_type==='CASE_LENGTH'?'case:length':'concept:name','actual rule key');
    const values=rule.primary_values.map(value=>rule.filter_type==='CASE_LENGTH'?{operation:value.operation,long_value:value.long_value}:{operation:value.operation,string_set:value.string_set});
    return rule.filter_type==='CASE_LENGTH'?{filter_type:rule.filter_type,choice:rule.choice,section:rule.section,primary_values:values}:{filter_type:rule.filter_type,choice:rule.choice,section:rule.section,inclusion:rule.inclusion,key:rule.key,primary_values:values};
  });
}
export function compareExtendedFilterCase(java,rust,spec,input) {
  assert.equal(java.engine_identity.class,'org.apromore.apmlog.filter.APMLogFilter');
  assert.equal(java.engine_identity.sha256.toLowerCase(),'b07c241d7d5a430f9fd1f6cea5eb696a71eefdee7dc268ee0c81d18c464769b3');
  assert.equal(java.case_length_identity.sha256.toLowerCase(),'1409e5c3cf4e730cf33eae022fc159a29c557eb98106849523ddd1e0f86c64be');
  assert.equal(rust.engine,'process_intelligence_rs::filters::apply');
  assert.equal(rust.status,'ACTUAL_RUST_EXTENDED_FILTER_OBSERVED');assert.equal(rust.engine_call_count,1);
  assert.equal(java.one_java_ordered_rule_list,true);
  for(const observed of [java,rust]) {assert(same(observed.filter_spec,input.filter_spec),'complete actual FilterSpec');assert(same(observed.source_domain_before,input.source),'complete actual source domain');}
  const jinvoked=java.engine_invoked===true;
  const javaDomainUnchanged=same(java.source_domain_before,java.source_domain_after)&&java.source_domain_before_sha256===java.source_domain_after_sha256;
  const rustDomainUnchanged=same(rust.source_domain_before,rust.source_domain_after)&&rust.source_before_sha256===rust.source_after_sha256&&rust.source_unchanged;
  const javaXlogUnchanged=same(java.source_xlog_before,java.source_xlog_after_conversion)&&java.source_xlog_before_sha256===java.source_xlog_after_conversion_sha256&&(!jinvoked||(same(java.source_xlog_before,java.source_xlog_after_filter)&&java.source_xlog_before_sha256===java.source_xlog_after_filter_sha256));
  const javaApmUnchanged=jinvoked?same(java.source_apm_before,java.source_apm_after)&&java.source_apm_before_sha256===java.source_apm_after_sha256:null;
  const observedJava={outcome:java.outcome,engine_invoked:java.engine_invoked,engine_call_count:java.engine_call_count??null,selected_source_indices:java.selected_source_indices??null,selected_event_positions:java.selected_event_positions??null,selected_source_log:java.selected_source_log??null,source_domain_unchanged:javaDomainUnchanged,source_xlog_unchanged:javaXlogUnchanged,source_apm_unchanged:javaApmUnchanged};
  const observedRust={outcome:rust.outcome,error_code:rust.error?.code??null,selected_source_indices:rust.selected_source_indices??null,selected_event_positions:rust.selected_event_positions??null,selected_source_log:rust.selected_source_log??null,source_domain_unchanged:rustDomainUnchanged};
  const javaChecks=fieldChecks(spec.expected_java,observedJava),rustChecks=fieldChecks(spec.expected_rust,observedRust);
  const ruleChecks=jinvoked?same(rulesProjection(java.java_ordered_rules),spec.java_ordered_rules):false;
  const javaConservation=conservation(java,input),rustConservation=conservation(rust,input);
  const pointerIdentity=jinvoked&&Array.isArray(java.selected_pointer_traces)&&same(java.selected_pointer_traces.map(row=>({index:row.immutable_trace_index,id:row.source_case_id,name:row.case_id,events:row.valid_event_indices})),java.selected_source_indices.map((n,i)=>({index:n,id:input.source.cases[n].id,name:input.source.cases[n].name,events:java.selected_event_positions[i]})));
  const selectedEqual=same(java.selected_source_log??null,rust.selected_source_log??null);
  const indicesEqual=same(java.selected_source_indices??null,rust.selected_source_indices??null)&&same(java.selected_event_positions??null,rust.selected_event_positions??null);
  const conserved=(javaConservation!==null&&all(javaConservation))&&(rustConservation===null?rust.outcome==='refused':all(rustConservation));
  return {id:spec.id,profile:spec.profile,input_sha256:spec.sha256,java:observedJava,rust:observedRust,actual_java_ordered_rules:java.java_ordered_rules??null,java_rules_match_frozen_parameters:ruleChecks,java_pointer_identity_binds_source:pointerIdentity,java_selection_conservation:javaConservation,rust_selection_conservation:rustConservation,rust_filter_spec_unchanged:rust.filter_spec_unchanged,selected_full_log_equal:selectedEqual,source_trace_and_event_indices_equal:indicesEqual,selected_full_log_differences:fieldDifferences(java.selected_source_log??null,rust.selected_source_log??null),original_manual_hypotheses:{java:spec.expected_java,rust:spec.expected_rust},hypothesis_checks:{java:javaChecks,rust:rustChecks},all_frozen_hypotheses_match:all(javaChecks)&&all(rustChecks)&&ruleChecks&&pointerIdentity&&conserved&&rust.filter_spec_unchanged,full_selection_equality_eligible:spec.full_selection_equality_expected,overlap_fields_match:spec.full_selection_equality_expected?selectedEqual&&indicesEqual&&conserved&&javaDomainUnchanged&&javaXlogUnchanged&&javaApmUnchanged&&rustDomainUnchanged&&pointerIdentity&&ruleChecks&&rust.filter_spec_unchanged:null,diagnostic_difference_is_not_equality_pass:!spec.full_selection_equality_expected,no_whole_Core_filter_parity_claim:true};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) runCorpus('oracle-core-filter-extended','87d9c3731c66eedc0bf54fbb7a6652c8b20f507c9a1000f3d0ffeac46acfe5d3',compareExtendedFilterCase);
