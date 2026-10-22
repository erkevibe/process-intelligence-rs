// Observe frozen calendar fields only; never implement business duration here.
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {assert,same,fieldDifferences,fieldChecks,all,exactInteger,runCorpus} from './compare-core-reference-support.mjs';
const OFFSETS=Object.freeze({ordinary:[0,0],clip:[0,0],weekend:[0,0],holiday:[0,0],'nonhour-zone':[20700,20700],'spring-elapsed':[3600,7200],'fall-elapsed':[7200,3600],'spring-gap-boundary':[3600,7200],'fall-fold-boundary':[7200,3600],'invalid-zone':null,'overnight-invalid':[0,0],reversed:[0,0],'precision-api':[0,0]});
function localInstant(value, expectedUtc, expectedOffset) {
  if(typeof value!=='string') return {matches:false,observed_offset_seconds:null,instant_matches:false};
  const plain=value.replace(/\[[^\]]+\]$/,'');
  const match=/(Z|([+-])(\d\d):(\d\d)(?::(\d\d))?)$/.exec(plain);
  if(!match) return {matches:false,observed_offset_seconds:null,instant_matches:false};
  const seconds=match[1]==='Z'?0:(match[2]==='-'?-1:1)*(Number(match[3])*3600+Number(match[4])*60+Number(match[5]??0));
  const instant=Date.parse(plain),frozen=Date.parse(expectedUtc);
  return {matches:Number.isFinite(instant)&&instant===frozen&&seconds===expectedOffset,observed_offset_seconds:seconds,expected_offset_seconds:expectedOffset,instant_matches:Number.isFinite(instant)&&instant===frozen};
}
function configurationBinding(config,input) {
  if(!config) return false;
  const minute=value=>/^\d\d:\d\d$/.test(value)?Number(value.slice(0,2))*60+Number(value.slice(3)):null;
  return config.zone_id===input.timezone
    && same(config.work_days.map(row=>({weekday:row.weekday,start_minute:minute(row.start_time),end_minute:minute(row.end_time),working_day:row.working_day})),input.weekdays.map(day=>({weekday:day,start_minute:input.start_minute,end_minute:input.end_minute,working_day:true})))
    && same(config.holidays.map(row=>({type:row.type,date:row.date})),input.holidays.map(date=>({type:'PUBLIC',date})));
}
export function compareCalendarCase(java,rust,spec,input) {
  assert.equal(java.calendar_identity.class,'org.apromore.calendar.model.CalendarModel');
  assert.equal(java.calendar_identity.sha256.toLowerCase(),'875c96a343e48cdc42c613b5f65ba7b35056498e112ebffd865084c4ad8c1e39');
  assert.equal(java.workday_identity.sha256.toLowerCase(),'e9983bdef6b0fe12f0d7db7bb03c326fdb1259a69cdf34bb8e0d279bb3217207');
  assert.equal(java.builder_identity.sha256.toLowerCase(),'8e2fefee2d943e7e8864d80d9cdfdaf8ce42ebb18e3002639d449a31c81096c5');
  assert.equal(java.factory_identity.sha256.toLowerCase(),'ec2958c284cb6d88b4a69b3ff24668c7311ccd19cfcd4ed396486863252ac5b2');
  assert.equal(java.main_method,'getDuration(Instant,Instant).toMillis()');
  assert.equal(java.secondary_method,'getDurationMillis(Instant,Instant)');
  assert.equal(rust.engine,'process_intelligence_rs::calendar::business_millis');
  assert.equal(rust.status,'ACTUAL_RUST_BUSINESS_CALENDAR_OBSERVED');
  for(const observation of [java,rust]) assert(same(observation.source_input_before,input),'complete frozen source input');
  const inputUnchanged=observation=>same(observation.source_input_before,observation.source_input_after)&&observation.source_input_before_sha256===observation.source_input_after_sha256;
  const mainSucceeded=java.duration_method_invoked===true&&java.duration_seconds!==null&&java.duration_seconds!==undefined&&java.duration_nanos!==null&&java.duration_nanos!==undefined&&java.duration_millis!==null&&java.duration_millis!==undefined;
  const secondarySucceeded=mainSucceeded&&java.secondary_method_invoked===true&&java.get_duration_millis_secondary!==null&&java.get_duration_millis_secondary!==undefined&&java.exception_stage!=='CalendarModel.getDurationMillis';
  const configAvailable=java.configuration_available===true;
  const conserved=configAvailable?same(java.configuration_before,java.configuration_after)&&java.configuration_before_sha256===java.configuration_after_sha256:null;
  const observedJava={outcome:mainSucceeded?'duration':java.outcome,duration_method_invoked:java.duration_method_invoked,duration_millis:java.duration_millis??null,exception_class:java.exception?.root?.class??null,configuration_unchanged:conserved,tzdb_version_hypothesis:configAvailable&&Array.isArray(java.java_zone_rules_versions)?(java.java_zone_rules_versions.includes(spec.expected_java.tzdb_version_hypothesis)?spec.expected_java.tzdb_version_hypothesis:java.java_zone_rules_versions.join(',')):null,configuration_available:configAvailable,source_input_unchanged:inputUnchanged(java)};
  if(Object.hasOwn(spec.expected_java,'duration_seconds')) Object.assign(observedJava,{duration_seconds:java.duration_seconds??null,duration_nanos:java.duration_nanos??null,get_duration_millis_secondary:secondarySucceeded?java.get_duration_millis_secondary:null});
  if(Object.hasOwn(spec.expected_java,'exception_stage')) observedJava.exception_stage=java.exception_stage??null;
  const observedRust={outcome:rust.outcome,duration_millis:rust.duration_millis??null,error_code:rust.error?.code??null,configuration_unchanged:rust.configuration_unchanged&&inputUnchanged(rust),iana_tzdb_version:rust.iana_tzdb_version};
  const javaChecks=fieldChecks(spec.expected_java,observedJava),rustChecks=fieldChecks(spec.expected_rust,observedRust);
  const offsetExpected=OFFSETS[spec.id];assert(offsetExpected!==undefined,'frozen independent offset case');
  const offsets=offsetExpected===null?null:{start:localInstant(java.local_start,input.start,offsetExpected[0]),end:localInstant(java.local_end,input.end,offsetExpected[1])};
  const offsetsMatch=offsets===null?!configAvailable:offsets.start.matches&&offsets.end.matches;
  const utcSegments=spec.derivation.utc_contributing_segments.map(segment=>{
    assert(segment.start.endsWith('Z')&&segment.end.endsWith('Z'),'explicit frozen UTC boundaries');
    return Date.parse(segment.end)-Date.parse(segment.start)===segment.elapsed_millis;
  });
  const utcSum=spec.derivation.utc_contributing_segments.reduce((sum,segment)=>sum+segment.elapsed_millis,0);
  const utcDerivationValid=utcSegments.every(Boolean)&&(spec.expected_rust.duration_millis===null||utcSum===spec.expected_rust.duration_millis);
  const tupleConsistent=mainSucceeded?Number.isInteger(java.duration_nanos)&&java.duration_nanos>=0&&java.duration_nanos<1000000000&&exactInteger(java.duration_seconds)*1000n+BigInt(Math.floor(java.duration_nanos/1000000))===exactInteger(java.duration_millis):null;
  const configBinding=configAvailable?configurationBinding(java.configuration_before,input.calendar):null;
  const afterMainConserved=mainSucceeded&&java.configuration_after_main?same(java.configuration_before,java.configuration_after_main)&&java.configuration_before_sha256===java.configuration_after_main_sha256:null;
  const mainEqual=mainSucceeded&&rust.outcome==='duration'&&same(java.duration_millis,rust.duration_millis);
  return {id:spec.id,profile:spec.profile,input_sha256:spec.sha256,java:observedJava,rust:observedRust,java_outer_outcome:java.outcome,main_succeeded:mainSucceeded,secondary_succeeded:secondarySucceeded,secondary_exception:java.exception_stage==='CalendarModel.getDurationMillis'?java.exception:null,main_duration_tuple_consistent:tupleConsistent,main_duration_equal:mainEqual,main_equality_eligible:spec.main_duration_equality_expected,main_overlap_fields_match:spec.main_duration_equality_expected?mainEqual&&conserved&&afterMainConserved&&configBinding&&offsetsMatch&&inputUnchanged(java)&&observedRust.configuration_unchanged&&tupleConsistent:null,secondary_api_difference_expected:spec.secondary_api_difference_expected,secondary_equality_not_claimed:spec.secondary_api_difference_expected,configuration_binds_input:configBinding,configuration_after_main_conserved:afterMainConserved,actual_java_zone_rules_versions:java.java_zone_rules_versions??null,actual_rust_iana_tzdb_version:rust.iana_tzdb_version,rust_offsets_directly_observed:false,rust_duration_checked_against_frozen_utc_segments:true,independent_offset_checks:offsets,independent_offset_checks_match:offsetsMatch,frozen_utc_derivation_valid:utcDerivationValid,original_manual_hypotheses:{java:spec.expected_java,rust:spec.expected_rust},hypothesis_checks:{java:javaChecks,rust:rustChecks},all_frozen_hypotheses_match:all(javaChecks)&&all(rustChecks)&&offsetsMatch&&utcDerivationValid&&(configAvailable?configBinding:true),declared_diagnostic:spec.profile!=='overlap',no_whole_calendar_parity_claim:true};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) runCorpus('oracle-core-calendar','f363e0952bcc8c153b7e269eba6535787a856a7e8693961fdaeaf6cc77de347e',compareCalendarCase);
