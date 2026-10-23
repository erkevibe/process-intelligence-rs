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

def raw(path, limit=4*1024*1024):
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

need(root.is_dir() and not root.is_symlink() and not output.exists(), 'fresh_input_output')
rows = []
for case, reason in [('service','unexpected_service_exit'),('absolute','pg_stop_absolute_deadline'),('memory','worker_exit')]:
    folder = root/case
    b = load(folder/'broker-result.json')
    stop = utc(b['stop_utc'])
    need(b['stop_reason'] == reason and not b['kill_fault'], 'actual_stop_reason_no_kill_fault')
    need(b['failure'] == ('pg_stop_absolute_deadline' if case == 'absolute' else None), 'no_unexpected_failure')
    need(b['guard_failure'] is None, 'no_guard_failure')
    need(b['process_count'] == b['completed_count'] == 2, 'two_owned_processes')
    probe = b['post_stop_probe']
    need(probe['attempted'] is True and probe['refused'] is True and probe['exception_code']=='stop_latched_no_admission', 'actual_post_stop_refusal')
    need(probe['process_count_before']==probe['process_count_after']==2 and probe['resume_unchanged'] is True, 'no_post_stop_go')
    need(stop <= utc(b['kill_requests_completed_utc']) <= utc(b['cleanup_completed_utc']) < utc(b['collector_finalization_deadline']), 'bounded_stop_cleanup')
    ops = b['native_kill_operations']
    need(len(ops)==2 and {o['job_label'] for o in ops}=={'worker','child'}, 'two_assigned_job_stop_operations')
    for op in ops:
        need(op['operation']=='TerminateJobObject' and op['success'] is True and op['native_error']==0 and op['pid']==0, 'native_job_stop_success')
    for label in ['worker','child']:
        r=load(folder/(label+'.process.json'))
        identity(load(folder/(label+'.start.json')),r,label,stop,True)
        expected_exit=0 if (label=='child' and case=='service') or (label=='worker' and case=='memory') else 137
        need(r['native_exit']==expected_exit and r['source_status']=='captured' and not r['drain_timeout'], 'actual_exit_capture')
        out=b'adapter-worker\n' if label=='worker' else b'child-ready\n'
        err=b'adapter-error\n' if label=='worker' else b'child-error\n'
        stream_check(folder,label,r,'stdout',out)
        stream_check(folder,label,r,'stderr',err)
    watches=b['service_watchers']
    if case in ['service','memory']:
        need(set(watches)=={'child'}, 'exact_service_watch')
        w=watches['child']
        need(w['expected_exit'] is (case=='memory') and w['triggered'] is (case=='service'), 'expected_vs_unexpected_service_exit')
        child=load(folder/'child.process.json')
        need(utc(w['attached_utc']) <= utc(child['resume_utc']), 'watch_before_resume')
    else:
        need(not watches, 'absolute_no_service_watch')
    if case=='absolute':
        events=b['events']
        def event(name):
            found=[e for e in events if e['event']==name]
            need(len(found)==1,'one_'+name)
            return utc(found[0]['utc'])
        armed=event('CONTROL_ABSOLUTE_STOP_ARMED')
        begin=event('CONTROL_BROKER_BLOCK_BEGIN')
        end=event('CONTROL_BROKER_BLOCK_END')
        need(armed<=begin<=stop<end and utc(b['kill_requests_completed_utc'])<end,'managed_stop_while_broker_blocked')
        need(0.9 <= (end-begin).total_seconds() <= 5,'bounded_actual_block')
        need(b['absolute_stop_timer_fired'] is True,'timer_actually_fired')
    if case=='memory':
        proof=load(folder/'memory-proof.json')
        data=raw(folder/'memory.ndjson')
        lines=[json.loads(x,object_pairs_hook=pairs) for x in data.splitlines()]
        header,footer=lines[0],lines[-1]
        child=load(folder/'child.process.json')
        need(header['kind']=='header' and header['pid']==child['pid']==proof['pid'] and header['creation_filetime']==child['native_creation_filetime']==proof['creation_filetime'],'memory_native_identity')
        need(header['image_verified'] is True and header['interval_ms_intended']==50 and header['max_samples']==5000,'memory_fixed_bounds')
        samples=lines[1:-1]
        need(2<=len(samples)<=5000 and len(data)<=4*1024*1024,'memory_sample_bounds')
        for n,s in enumerate(samples,1):
            need(s['kind']=='sample' and s['number']==n,'memory_sample_sequence')
            for key in ['working_set','private_commit','lifetime_peak_working_set','lifetime_peak_commit','page_faults']:
                need(type(s[key]) is int and s[key]>=0,'native_memory_integer')
            need(s['lifetime_peak_working_set']>=s['working_set'],'working_peak_bound')
            if n>1:
                need(utc(samples[n-2]['utc'])<=utc(s['utc']),'memory_monotonic_observed_utc')
        need(samples[-1]['stage']=='warm_before','final_fresh_point_stage')
        need(footer=={'kind':'complete','samples':len(samples),'target_still_alive':True},'complete_memory_footer')
        need(proof['samples']==len(samples) and proof['sha256'].upper()==sha(data) and proof['complete'] is True and proof['fault'] is False,'memory_proof_binding')
        need(proof['wrong_identity_refused'] is True and not (folder/'wrong-identity.ndjson').exists(),'wrong_100ns_refused_before_file')
        dead=raw(folder/'dead-target.ndjson')
        dlines=[json.loads(x,object_pairs_hook=pairs) for x in dead.splitlines()]
        need(dlines and dlines[0]['kind']=='header' and dlines[0]['pid']==child['pid'] and dlines[0]['creation_filetime']==child['native_creation_filetime'],'dead_target_original_identity')
        need(all(s['kind']!='complete' for s in dlines),'dead_target_no_complete_footer')
        need(proof['dead_target_partial'] is True and proof['dead_target_sha256'].upper()==sha(dead),'dead_target_partial_hash')
        need(proof['dead_target_fault'] in ['memory_target_exited_before_final_snapshot','memory_final_target_not_alive'],'actual_dead_target_fault')
    rows.append({'scenario':case,'actual_native_exit_raw_streams_and_manual_adapter_oracles_verified':True})
outer=load(root/'collector.process.json')
start=load(root/'collector.start.json')
need(start['pid']==outer['pid'] and start['native_creation_utc']==outer['native_creation_utc'] and start['program']==outer['program'],'outer_native_identity')
need(outer['program_sha256'].upper()==PW_SHA and outer['native_exit']==1 and outer['stdout_complete'] and outer['stderr_complete'],'outer_actual_closure')
for side in ['stdout','stderr']:
    data=raw(root/('collector.'+side))
    need(len(data)==outer[side+'_bytes_persisted'] and sha(data)==outer[side+'_sha256'].upper(),'outer_raw_binding')
need(not outer['capture_fault'] and not outer['output_limit'] and not outer['drain_timeout'],'outer_no_faults')
need(not (root/'launch-result.json').exists(),'failed_phase_no_success_receipt')
need(raw(root/'collector.stdout')==b'' and raw(root/'collector.stderr')==b'Exception: resource_sample_timeout\r\n','exact_final_guard_failure')
need(time.monotonic()-started<45,'audit_deadline')
with output.open('x',encoding='utf-8') as stream:
    json.dump({'status':'INDEPENDENT_THREE_FIXTURE_ORACLES_VERIFIED_OVERALL_PHASE_FAILED_FINAL_GUARD','cases':rows,'overall_phase':'FAILED_GUARD','phase_success_claimed':False,'native_records':7,'full_stream_slots':14,'measurement_admitted':False,'historical_unknowns_unchanged':6,'scope':'Saved native records/raw byte oracles and reviewed adapter source; no product, PostgreSQL or network execution by auditor; no Root pass boolean used.'},stream,indent=2)