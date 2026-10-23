"""Independent finite saved-byte oracles for S22 ownership controls; no execution."""
import hashlib
import json
from pathlib import Path
import sys
import time
from datetime import datetime, timezone, timedelta

started = time.monotonic()
root, output = map(Path, sys.argv[1:3])
root = root.resolve(strict=True)
PW_SHA = '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
IDS = ['OWN-01', 'OWN-02', 'OWN-03', 'OWN-04', 'OWN-05', 'OWN-06', 'OWN-06B']
REASONS = ['worker_exit', 'worker_exit', 'child_timeout', 'output_or_capture_fault',
           'resource_guard_failure', 'ownership_confirmation_withheld', 'spawn_admission_failure']

def need(value, code):
    if not value:
        raise ValueError(code)

def raw(path, limit=1024*1024):
    need(time.monotonic()-started < 45, 'audit_deadline')
    need(path.resolve().is_relative_to(root), 'contained_input')
    p = path
    while p != root:
        need(not p.is_symlink() and not (getattr(p.lstat(), 'st_file_attributes', 0) & 1024), 'no_reparse')
        p = p.parent
    need(path.stat().st_size <= limit, 'input_bound')
    with path.open('rb') as stream:
        data = stream.read(limit+1)
    need(len(data) <= limit, 'read_bound')
    return data

def pairs(rows):
    value = {}
    for key, item in rows:
        need(key not in value, 'duplicate_json_key')
        value[key] = item
    return value

def load(path):
    return json.loads(raw(path), object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite_json')))

def sha(data):
    return hashlib.sha256(data).hexdigest().upper()

def utc(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))

def stream_check(folder, label, record, side, expected, complete=True):
    data = raw(folder / (label+'.'+side))
    need(data == expected, 'manual_raw_oracle_'+label+'_'+side)
    need(record[side+'_bytes_persisted'] == len(data), 'persisted_length')
    need(record[side+'_sha256'].upper() == sha(data), 'persisted_sha')
    need(record[side+'_capture_initialized'] is True, 'capture_initialized')
    need(record[side+'_eof'] is True, 'actual_eof')
    need(record[side+'_fault'] is False, 'capture_fault')
    need(record[side+'_complete'] is complete, 'complete_status')
    need(record[side+'_truncated'] is (not complete), 'truncation_status')
    observed = record[side+'_bytes_observed']
    need(type(observed) is int and observed >= len(data), 'observed_length')
    if complete:
        need(observed == len(data), 'complete_observed_length')
    else:
        need(observed > len(data), 'actual_discard_observed')

def identity(start, record, label, stop, resumed):
    need(start['label'] == record['label'] == label, 'label_identity')
    need(type(start['pid']) is int and start['pid'] > 0 and start['pid'] == record['pid'], 'pid_identity')
    creation = start['native_creation_filetime']
    need(type(creation) is int and creation > 0 and creation == record['native_creation_filetime'], 'native_creation_identity')
    # Compare integer FILETIME to UTC without floating point. Python datetimes
    # have microsecond precision; the original100ns integer remains authoritative.
    observed = datetime(1601, 1, 1, tzinfo=timezone.utc) + timedelta(microseconds=creation//10)
    need(utc(start['native_creation_utc']) == observed, 'native_creation_utc_floor')
    need(start['program'] == record['program'] and start['program'], 'image_identity')
    need(start['retained_native_handle'] is True and record['retained_native_handle'] is True, 'retained_handle')
    need(start['created_suspended'] is True and start['resumed'] is False, 'suspended_start')
    need(record['resumed'] is resumed, 'actual_resume_state')
    need(type(record['native_exit']) is int, 'actual_child_exit')
    if not start.get('admission_failed', False):
        need(start['job_member'] is True and start['collector_outside_job'] is True, 'positive_job_boundary')
        need(start['stdout_capture_ready'] is True and start['stderr_capture_ready'] is True, 'ready_before_resume')
        need(start['program_sha256'].upper() == PW_SHA, 'program_pin')
    if resumed:
        need(utc(start['utc']) <= utc(record['resume_utc']) <= stop, 'resume_before_stop')
    else:
        need(record['resume_utc'] is None, 'no_resume_timestamp')

need(root.is_dir() and not root.is_symlink() and not output.exists(), 'fresh_owned_input_output')
report = load(root/'controls-report.json')
need([r['id'] for r in report['rows']] == IDS, 'exact_seven_scenarios')
need(report['historical_unknowns'] == 6 and report['historical_unknowns_repaired'] is False,
     'history_unchanged')
need(report['measurement_admitted'] is False, 'no_self_measurement_admission')
rows = []
for case, reason in zip(IDS, REASONS):
    folder = root/case.lower()
    broker = load(folder/'broker-result.json')
    need(broker['stop_reason'] == reason and broker['kill_fault'] is False, 'expected_stop_no_kill_fault')
    need(broker['process_count'] == broker['completed_count'] == 2, 'all_created_children_recorded')
    need(broker['failure'] == ('spawn_admission_failure' if case == 'OWN-06B' else None), 'no_hidden_failure')
    stop = utc(broker['stop_utc'])
    deadline = utc(broker['collector_finalization_deadline'])
    need(0 < (deadline-stop).total_seconds() <= 25.01, 'stop_anchored_25second_deadline')
    need(stop <= utc(broker['kill_requests_completed_utc']) <= utc(broker['cleanup_completed_utc']) < deadline,
         'kill_then_cleanup_before_harddeadline')
    need(broker['receipt_write_hard_timer_still_armed'] is True and broker['collector_host_death_supported'] is False,
         'collector_scope')
    probe = broker['post_stop_probe']
    need(probe['attempted'] is True and probe['refused'] is True
         and probe['exception_code'] == 'stop_latched_no_admission'
         and probe['process_count_before'] == probe['process_count_after'] == 2
         and probe['resume_unchanged'] is True, 'actual_post_stop_refusal')
    operations = broker['native_kill_operations']
    need(len(operations) == 2, 'exact_two_fixed_job_operations')
    job_labels = set()
    for operation in operations:
        need(operation['operation'] == 'TerminateJobObject', 'fixed_cases_require_job_kill_only')
        need(operation['success'] is True and operation['native_error'] == 0, 'native_kill_success_no_error')
        need(utc(operation['utc']) <= utc(broker['kill_requests_completed_utc']), 'native_kill_observation_time')
        if operation['operation'] == 'TerminateJobObject':
            need(operation['job_label'] in ['worker','child'], 'owned_job_label')
            job_labels.add(operation['job_label'])
            if operation['already_stopped']:
                need(case == 'OWN-02' and operation['job_label'] == 'worker', 'replayed_prior_actual_control_kill')
            else:
                need(utc(operation['utc']) >= stop, 'new_job_kill_after_stop')
    need(job_labels == {'worker','child'}, 'both_owned_job_requests_observed')
    events = broker['events']
    need([e['sequence'] for e in events] == list(range(1,len(events)+1)), 'event_sequence')
    if case == 'OWN-02':
        need(any(e['event'] == 'CONTROL_KILL_WORKER' and e['label'] == 'worker' for e in events), 'actual_worker_kill_barrier')
    if case == 'OWN-05':
        guard = broker['guard_failure']
        need(guard['type'] == 'System.IO.IOException' and guard['hresult'] == -2147024864
             and guard['expected_owned_sharing_failure'] is True, 'actual_sharing_failure')
        need(guard['target'] == 'workspace:/.local/sprint21/root/sprint22/controls04/own-05/guard-denial.bin'
             and guard['message'] == "The process cannot access the file '" + guard['target'] + "' because it is being used by another process.", 'exact_guard_fixture')
        need(raw(folder/'guard-denial.bin') == b'S22', 'actual_guard_fixture_bytes')
    else:
        need(broker['guard_failure'] is None, 'no_unexpected_guard_failure')
    for label in ['worker','child']:
        start = load(folder/(label+'.start.json'))
        record = load(folder/(label+'.process.json'))
        resumed = not (label == 'child' and case in ['OWN-06','OWN-06B'])
        identity(start, record, label, stop, resumed)
        need(record['native_exit'] == (0 if case == 'OWN-01' else 137), 'manual_native_exit')
        if case == 'OWN-06B' and label == 'child':
            need(start['admission_failed'] is True and record['source_status'] == 'missing_or_fault', 'explicit_partial_spawn')
            for side in ['stdout','stderr']:
                need(record[side+'_capture_initialized'] is False and record[side+'_eof'] is False
                     and record[side+'_complete'] is False and record[side+'_bytes_observed'] is None
                     and record[side+'_sha256'] is None, 'no_fabricated_uninitialized_stream')
                need(not (folder/(label+'.'+side)).exists(), 'uninitialized_stream_not_created')
        else:
            need(record['drain_timeout'] is False, 'no_drain_timeout')
            if label == 'worker':
                stream_check(folder,label,record,'stdout',b'worker-ready\n')
                stream_check(folder,label,record,'stderr',b'worker-error\n')
            elif case == 'OWN-04':
                stream_check(folder,label,record,'stdout',b'X'*4096,False)
                stream_check(folder,label,record,'stderr',b'child-flood\n')
                need(record['source_status'] == 'truncated', 'explicit_output_limit')
            elif case == 'OWN-06':
                stream_check(folder,label,record,'stdout',b'')
                stream_check(folder,label,record,'stderr',b'')
            else:
                stream_check(folder,label,record,'stdout',b'child-ready\n')
                stream_check(folder,label,record,'stderr',b'child-error\n')
                need(record['source_status'] == 'captured', 'full_capture_status')
    rows.append({'id':case,'manual_raw_streams_and_native_exit_verified':True,
                 'partial_capture_is_deliberate_negative_only':case == 'OWN-06B'})

# The outer collector uses the earlier runtime's separately captured record.
outer = load(root/'collector.process.json')
outer_start = load(root/'collector.start.json')
need(outer_start['pid'] == outer['pid'] and outer_start['native_creation_utc'] == outer['native_creation_utc']
     and outer_start['program'] == outer['program']
     and outer['program_sha256'].upper() == PW_SHA, 'outer_identity_binding')
need(outer['native_exit'] == 0 and outer['stdout_complete'] is True and outer['stderr_complete'] is True,
     'outer_actual_closure')
for side in ['stdout','stderr']:
    data = raw(root/('collector.'+side))
    need(len(data) == outer[side+'_bytes_persisted'] and sha(data) == outer[side+'_sha256'].upper(), 'outer_raw_stream_binding')
need(not outer['capture_fault'] and not outer['output_limit'] and not outer['drain_timeout'], 'outer_capture_faults')
need(time.monotonic()-started < 45, 'audit_deadline')
with output.open('x',encoding='utf-8') as stream:
    json.dump({'status':'INDEPENDENT_SEVEN_SAVED_OWNERSHIP_SCENARIOS_MANUAL_ORACLES_VERIFIED',
               'cases':rows,'historical_unknowns_unchanged':6,'measurement_admitted':False,
               'no_native_or_network_execution_by_auditor':True,
               'limitations':['Saved-file audit binds actual observations and reviewed owner source; it does not survive or repair arbitrary collector/host death.',
                              'OWN06B intentionally has no initialized child capture and is never counted as full EOF.',
                              'No report rows or Root-observed-pass booleans are used as acceptance oracles.']},stream,indent=2)
