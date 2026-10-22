// Counterfactual comparator tests ONLY. These objects are not engine evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readJson} from './compare-core-reference-support.mjs';
import {compareCalendarCase} from './compare-core-calendar.mjs';
function sample() {
  const corpus=readJson('fixtures/oracle-core-calendar/corpus.json').value;
  const spec=corpus.cases.find(row=>row.id==='precision-api');
  const input=readJson('fixtures/oracle-core-calendar/'+spec.file).value;
  const config={zone_id:'UTC',work_days:[{weekday:1,start_time:'09:00',end_time:'18:00',working_day:true}],holidays:[],created:'counterfactual-test-only'};
  const java={calendar_identity:{class:'org.apromore.calendar.model.CalendarModel',sha256:'875c96a343e48cdc42c613b5f65ba7b35056498e112ebffd865084c4ad8c1e39'},workday_identity:{sha256:'e9983bdef6b0fe12f0d7db7bb03c326fdb1259a69cdf34bb8e0d279bb3217207'},builder_identity:{sha256:'8e2fefee2d943e7e8864d80d9cdfdaf8ce42ebb18e3002639d449a31c81096c5'},factory_identity:{sha256:'ec2958c284cb6d88b4a69b3ff24668c7311ccd19cfcd4ed396486863252ac5b2'},main_method:'getDuration(Instant,Instant).toMillis()',secondary_method:'getDurationMillis(Instant,Instant)',source_input_before:input,source_input_after:structuredClone(input),source_input_before_sha256:'same',source_input_after_sha256:'same',configuration_available:true,configuration_before:config,configuration_after_main:structuredClone(config),configuration_after:structuredClone(config),configuration_before_sha256:'same-config',configuration_after_main_sha256:'same-config',configuration_after_sha256:'same-config',duration_method_invoked:true,secondary_method_invoked:true,duration_seconds:1,duration_nanos:250000000,duration_millis:1250,get_duration_millis_secondary:1251,java_zone_rules_versions:['2026b'],outcome:'duration',local_start:'2026-06-01T09:00Z[UTC]',local_end:'2026-06-01T09:00:01.250Z[UTC]'};
  const rust={engine:'process_intelligence_rs::calendar::business_millis',status:'ACTUAL_RUST_BUSINESS_CALENDAR_OBSERVED',source_input_before:input,source_input_after:structuredClone(input),source_input_before_sha256:'same',source_input_after_sha256:'same',outcome:'duration',duration_millis:1250,error:null,configuration_unchanged:true,iana_tzdb_version:'2025b'};
  return {java,rust,spec,input};
}
const compare=s=>compareCalendarCase(s.java,s.rust,s.spec,s.input);
test('main precision and separately frozen secondary value',()=>{const r=compare(sample());assert.equal(r.all_frozen_hypotheses_match,true);assert.equal(r.main_overlap_fields_match,true);assert.equal(r.secondary_equality_not_claimed,true);});
test('secondary-only exception does not erase successful main',()=>{const s=sample();Object.assign(s.java,{outcome:'duration_refused',get_duration_millis_secondary:null,exception_stage:'CalendarModel.getDurationMillis',exception:{root:{class:'counterfactual.SecondaryException'}}});const r=compare(s);assert.equal(r.main_succeeded,true);assert.equal(r.main_duration_equal,true);assert.equal(r.main_overlap_fields_match,true);assert.equal(r.secondary_succeeded,false);assert.equal(r.all_frozen_hypotheses_match,false);});
test('version match cannot excuse wrong observed offset',()=>{const s=sample();s.java.local_start='2026-06-01T10:00+01:00';const r=compare(s);assert.equal(r.independent_offset_checks.start.instant_matches,true);assert.equal(r.independent_offset_checks_match,false);assert.equal(r.all_frozen_hypotheses_match,false);});
test('full public configuration mutation is visible',()=>{const s=sample();s.java.configuration_after.created='changed';assert.equal(compare(s).java.configuration_unchanged,false);});
test('seconds/nanos/main-millis disagreement remains false',()=>{const s=sample();s.java.duration_nanos=249000000;assert.equal(compare(s).main_duration_tuple_consistent,false);});
