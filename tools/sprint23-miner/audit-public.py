"""One saved fixed SplitMiner scale trial; no engine, subprocess or quality claim.

CLI: SOURCE TRIAL_ROOT OUTPUT --oracle OLD_BENCHMARK_AUDITOR --semantic
FULL_GRAPH_AUDITOR --reference LINEAR_BPMN --projection MANIFEST
--ownership-review PUBLIC_SAFE_PRIVATE_ACCEPTANCE. This separate public replay
binds original raw native captures via the explicit path-only projection.
Pre-GO ownership is NOT replayed: its private actual review is pinned separately.
Collector closure and original-to-public transformation review remain separate.
"""
import argparse
import hashlib
import importlib.util
import json
from decimal import Decimal
from pathlib import Path
import time
import xml.etree.ElementTree as ET

SOURCE = 'c2196dd7376c94f17e2b6b5a4cdbe5ec620b10ca008130418abc6d7558af59f1'
REFERENCE = '427e4dbded59fa732b2cef5b48ab47a414a4461331bdcc4b19b13db338c0eac5'
ORACLE = 'def4962492a2338cf9d1b68d037eadfbfdaff27a755e0fef1c7f5004d9ec1b93'
SEMANTIC = '17479acca0cd6587b91002b8c58e7279c70c702e571189402b195b7d1cdf1878'
OWNERSHIP_REVIEW = '61870368a2c5e265ed881e3da4b0f0a90a6610069a5b6a6e776094f47b0d5879'
PID = 'cold-r1-scale-linear'
CALL = PID + '-measure-1'
START = time.monotonic()


def need(ok, why):
    if not ok:
        raise ValueError(why)
    if time.monotonic() - START > 45:
        raise ValueError('audit_deadline')


def raw(path, cap=8*1024*1024):
    path = Path(path).absolute()
    anchor = Path.cwd().absolute()
    need(path.is_relative_to(anchor), 'workspace_scope')
    chain = [path]
    while chain[-1] != anchor:
        chain.append(chain[-1].parent)
    for node in chain:
        need(not (node.lstat().st_file_attributes & 0x400)
             if hasattr(node.lstat(), 'st_file_attributes') else not node.is_symlink(),
             'reparse')
    need(path.is_file() and path.stat().st_size <= cap, 'file_bound')
    with path.open('rb') as f:
        value = f.read(cap+1)
    need(len(value) <= cap, 'file_grew')
    return value


def sha(value):
    return hashlib.sha256(value).hexdigest()


def module(name, path, expected):
    need(sha(raw(path)) == expected, 'auditor_source_pin')
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def integer(value, minimum=0):
    need(type(value) is int and value >= minimum, 'integer_type_or_range')
    return value


def typed_equal(left, right):
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(typed_equal(left[k], right[k]) for k in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(typed_equal(x,y) for x,y in zip(left,right))
    return left == right


def xml(value):
    need(len(value) <= 4*1024*1024 and b'<!DOCTYPE' not in value.upper()
         and b'<!ENTITY' not in value.upper() and b'\0' not in value, 'xml_bound')
    return ET.fromstring(value.decode('utf-8', errors='strict'))


def source(value):
    need(len(value) == 109566 and sha(value) == SOURCE, 'fixed_source')
    root = xml(value)
    ns = '{http://www.xes-standard.org/}'
    need(root.tag == ns+'log' and root.attrib == {'xes.version':'1.0'}, 'log_schema')
    need(len(root) == 500, 'trace_count')
    for i, trace in enumerate(root):
        need(trace.tag == ns+'trace' and not trace.attrib and len(trace) == 4, 'trace_shape')
        need(trace[0].tag == ns+'string' and trace[0].attrib ==
             {'key':'concept:name','value':f'case{i:04d}'} and not len(trace[0]), 'trace_identity')
        for event, label in zip(list(trace)[1:], 'ABC'):
            need(event.tag == ns+'event' and not event.attrib and len(event) == 1, 'event_shape')
            need(event[0].tag == ns+'string' and event[0].attrib ==
                 {'key':'concept:name','value':label} and not len(event[0]), 'event_identity')


def manual_graph(value):
    ns = '{http://www.omg.org/spec/BPMN/20100524/MODEL}'
    root = xml(value)
    processes = root.findall(ns+'process')
    need(len(processes) == 1, 'one_process')
    nodes = [x for x in processes[0] if x.tag != ns+'sequenceFlow']
    edges = [x for x in processes[0] if x.tag == ns+'sequenceFlow']
    need(len(nodes) == 5 and len(edges) == 4, 'manual_graph_size')
    identities = {}
    for node in nodes:
        kind = node.tag.removeprefix(ns)
        name = node.get('name', '')
        token = kind if kind in ('startEvent','endEvent') else name
        need(kind in ('startEvent','endEvent','task') and token in
             ('startEvent','endEvent','A','B','C') and token not in identities.values(), 'manual_node')
        identities[node.attrib['id']] = token
    need({(identities[e.attrib['sourceRef']], identities[e.attrib['targetRef']]) for e in edges}
         == {('startEvent','A'),('A','B'),('B','C'),('C','endEvent')}, 'manual_ABC_chain')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('source', type=Path); p.add_argument('trial_root', type=Path)
    p.add_argument('output', type=Path)
    for name in ('oracle','semantic','reference'):
        p.add_argument('--'+name, required=True, type=Path)
    p.add_argument('--projection', required=True, type=Path)
    p.add_argument('--ownership-review', required=True, type=Path)
    a = p.parse_args()
    need(not a.output.exists(), 'fresh_output')
    source(raw(a.source, 1024*1024))
    o = module('saved_benchmark_oracle', a.oracle, ORACLE)
    o.read = raw  # Apply workspace-bound no-reparse and bounded reads transitively.
    projection = o.PublicProjection(a.projection)
    review_raw = raw(a.ownership_review, 1024*1024)
    need(sha(review_raw) == OWNERSHIP_REVIEW, 'actual_private_ownership_review_pin')
    review = o.parse(review_raw)
    need(review['status'] == 'ACTUAL_FIXED_500_ABC_SPLITMINER_PRIVATE_TECHNICAL_ACCEPTANCE'
         and review['config_sha256'] == '15121E5B10D42E56A5AF4856F51A4AD454457FC903712C6DC2559F1A77D3799D',
         'actual_private_review_scope')
    s = module('full_bpmn_bijection', a.semantic, SEMANTIC)
    reference = raw(a.reference, 4*1024*1024)
    need(sha(reference) == REFERENCE, 'reference_pin')
    index = o.parse(raw(a.trial_root/'index.json'))
    need(index['fixed_input_sha256'].lower() == SOURCE and len(index['processes']) == 1,
         'one_fixed_trial')
    trial = index['processes'][0]
    need(trial['process_id'] == PID and trial['case_id'] == 'scale-linear'
         and trial['regime'] == 'cold-fresh-jvm' and trial['status'] == 'completed'
         and trial['failure'] is None, 'trial_status')
    need(o.parse(raw(a.trial_root/PID/'trial.json')) == trial, 'trial_index_binding')
    need(typed_equal(trial['scheduled_calls'], [{'call_id':CALL,'role':'measured',
         'ordinal_in_process':1,'primary_timing_eligible':True}]), 'single_schedule')
    record, streams, record_sha = o.native(a.trial_root, trial['native_record_path'], projection=projection)
    o.fresh_identity(set(), record)
    boot, terminal = o.protocols(streams['stdout'])
    need(terminal == trial['terminal'], 'terminal_binding')
    resultdir = o.child(a.trial_root, trial['result_directory'])
    _, ready_raw = o.descriptor(resultdir, terminal['terminal_ready'], 65536)
    ready = o.parse(ready_raw)
    _, summary_raw = o.descriptor(resultdir, terminal['summary'], 8*1024*1024)
    summary = o.parse(summary_raw)
    _, ledger_raw = o.descriptor(resultdir, terminal['ledger'])
    ledger = [o.parse(line) for line in ledger_raw.splitlines() if line]
    need([x['event'] for x in ledger] == ['call_started','call_completed']
         and all(x['call_id'] == CALL for x in ledger), 'single_actual_ledger')
    for row in (boot,terminal,ready,summary):
        need(row['process_id'] == PID and row['pid'] == record['pid']
             and row['nonce'] == boot['nonce'], 'protocol_identity')
    need(ready['summary'] == terminal['summary'] and ready['ledger'] == terminal['ledger'], 'ready_binding')
    need(summary['input_sha256'].lower() == SOURCE and summary['regime'] == 'cold'
         and summary['assertions_enabled'] is False, 'summary_source_regime')
    need(typed_equal(summary['parameters'], {
        'percentile_frequency_threshold':Decimal('0.4'),
        'parallelisms_threshold':Decimal('0.1'),'filter_type':'WTH',
        'parallelisms_first':False,'replace_iors':True,'remove_loop_activities':False,
        'structuring_time':'NONE','classifier':'org.deckfour.xes.classification.XEventNameClassifier'}),
        'unchanged_algorithm_parameters')
    need(all(integer(row[key], 1) == 1 for row in (summary,terminal)
             for key in ('scheduled_calls','completed_calls')), 'call_counts')
    expected, environment_proof = o.environment(a.trial_root, index, projection=projection)
    o.observed_classes(summary, expected)
    jvm = o.jvm_flags(summary)
    need(len(summary['iterations']) == 1, 'iteration_count')
    obs = summary['iterations'][0]
    _, obs_raw = o.descriptor(resultdir, ledger[1]['observation'])
    need(typed_equal(o.parse(obs_raw), obs) and
         typed_equal(obs, o.parse(raw(resultdir/(CALL+'.json'), 1024*1024))), 'full_observation_binding')
    need(obs['call_id'] == CALL and obs['process_id'] == PID and obs['case_id'] == 'scale-linear'
         and obs['role'] == 'measured' and integer(obs['ordinal_in_process'],1) == 1
         and obs['engine_invoked'] is True and obs['status'] == 'diagram_returned', 'engine_observation')
    for key in ('parse_time_nanos','engine_time_nanos','export_time_nanos'):
        integer(obs[key])
    integer(ready['active_pipeline_nanos'])
    need(obs['engine_time_nanos'] <= ready['active_pipeline_nanos'], 'engine_pipeline_boundary')
    need(obs['input_sha256'].lower() == SOURCE and obs['input_traces'] == 500
         and obs['input_events'] == 1500 and obs['input_xlog_unchanged'] is True
         and typed_equal(obs['input_xlog_before'], obs['input_xlog_after'])
         and obs['input_xlog_before_sha256'] == obs['input_xlog_after_sha256'], 'source_conservation')
    model = obs['input_xlog_before']
    need(sha(json.dumps(model, ensure_ascii=False, separators=(',',':')).encode('utf-8'))
         == obs['input_xlog_before_sha256'], 'typed_xlog_canonical_hash')
    need(set(model) == {'attributes','classifiers','extensions','global_trace_attributes',
         'global_event_attributes','traces','trace_count','event_count'} and
         all(model[k] == [] for k in ('attributes','classifiers','extensions',
                                     'global_trace_attributes','global_event_attributes')), 'full_log_attributes')
    need(model['trace_count'] == len(model['traces']) == 500 and model['event_count'] == 1500, 'full_xlog_counts')
    for i, trace in enumerate(model['traces']):
        need(set(trace) == {'attributes','events'} and trace['attributes'] == [{'key':'concept:name','type':'string','value':f'case{i:04d}'}]
             and len(trace['events']) == 3, 'full_trace_attributes')
        for event, label in zip(trace['events'], 'ABC'):
            need(set(event) == {'attributes'} and event['attributes'] == [{'key':'concept:name','type':'string','value':label}], 'full_event_attributes')
    _, bpmn = o.descriptor(resultdir, obs['bpmn'], 1024*1024)
    need({x['file'] for x in summary['artifacts']} == {CALL+'.json',obs['bpmn']['file']}
         and len(summary['artifacts']) == 2, 'exact_artifacts')
    for item in summary['artifacts']:
        o.descriptor(resultdir, item, 1024*1024)
    manual_graph(bpmn)
    graph = s.compare(reference, bpmn)
    need(graph['status'] == 'exact_full_semantic_bijection' and graph['semantic_equal'] is True,
         'full_semantic_bijection')
    graph.pop('audit_wall_seconds', None)
    bootc = o.parse(raw(a.trial_root/PID/'boot-counters.json'))
    live = o.parse(raw(o.child(a.trial_root, trial['live_counters_path'])))
    need(bootc['protocol'] == boot and live['terminal'] == terminal, 'counter_protocol')
    for c in (bootc,live):
        need(c['native_creation_utc'] == record['native_creation_utc'] ==
             o.filetime_iso(c['process_cpu']['creation_filetime_100ns'])
             and c['process_cpu']['exit_filetime_100ns'] is None, 'live_native_identity')
        for key in ('peak_working_set_bytes','current_working_set_bytes',
                    'peak_private_commit_bytes','current_private_commit_bytes','page_faults'):
            integer(c['process_memory'][key])
        need(c['process_memory']['peak_working_set_bytes'] >= c['process_memory']['current_working_set_bytes']
             and c['process_memory']['peak_private_commit_bytes'] >= c['process_memory']['current_private_commit_bytes'], 'memory_highwater')
    after = trial['process_cpu_after_exit']
    need(after['creation_filetime_100ns'] == live['process_cpu']['creation_filetime_100ns'], 'postexit_identity')
    integer(after['exit_filetime_100ns'], after['creation_filetime_100ns'])
    for key in ('user_cpu_100ns','kernel_cpu_100ns'):
        values = [integer(c['process_cpu'][key]) for c in (bootc,live)] + [integer(after[key])]
        need(values == sorted(values), 'cpu_monotonic')
    for key in ('peak_working_set_bytes','peak_private_commit_bytes'):
        need(bootc['process_memory'][key] <= live['process_memory'][key], 'memory_monotonic')
    jobs = [bootc['job'],live['job'],trial['job_after_exit']]
    for c in jobs:
        for key in ('peak_job_commit_bytes','peak_single_process_commit_bytes','user_cpu_100ns',
                    'kernel_cpu_100ns','total_processes','active_processes','limit_terminated_processes','page_faults'):
            integer(c[key])
        need(c['total_processes'] == 1 and c['limit_terminated_processes'] == 0, 'one_java_job')
    need([c['active_processes'] for c in jobs] == [1,1,0], 'job_liveness')
    for key in ('peak_job_commit_bytes','peak_single_process_commit_bytes','user_cpu_100ns','kernel_cpu_100ns','page_faults'):
        need([c[key] for c in jobs] == sorted(c[key] for c in jobs), 'job_monotonic')
    freq = integer(trial['stopwatch_frequency'], 1)
    keys = ('boot_ready_ticks','go_dispatch_ticks','terminal_ready_ticks','exit_dispatch_ticks',
            'instrumented_process_lifetime_ticks','controller_including_capture_drain_ticks')
    ticks = [integer(trial[k]) for k in keys]
    need(ticks == sorted(ticks) and ticks[3]-ticks[2] <= 10*freq and ticks[4] <= 130*freq, 'controller_bounds')
    need(live['stopwatch_frequency'] == freq and all(live[k] == trial[k] for k in keys[:3]), 'live_ticks')
    need(not (a.trial_root/PID/'ownership-before-go.json').exists(), 'private_ownership_file_must_be_omitted')
    output = {'status':'PUBLIC_FIXED_SCALE_SOURCE_FULL_BPMN_COUNTER_AND_ORIGINAL_CAPTURE_AUDIT_PASS',
              'projection_manifest_sha256':projection.manifest_sha256,
              'private_ownership_replayed':False,'private_ownership_review_sha256':OWNERSHIP_REVIEW,
              'source_sha256':SOURCE,'trace_count':500,'event_count':1500,'scheduled_calls':1,
              'bpmn_sha256':sha(bpmn),'semantic_bijection':graph,'projected_java_record_sha256':record_sha,
              'original_java_record_sha256':projection.original_sha(o.child(a.trial_root,trial['native_record_path'])),
              'engine_time_nanos':obs['engine_time_nanos'],'terminal_process_memory':live['process_memory'],
              'parse_time_nanos':obs['parse_time_nanos'],'export_time_nanos':obs['export_time_nanos'],
              'active_pipeline_nanos':ready['active_pipeline_nanos'],
              'controller_ticks':{k:trial[k] for k in ('stopwatch_frequency',*keys)},
              'process_cpu_after_exit':after,'job_after_exit':jobs[-1],'jvm_configuration':jvm,
              'environment_proof':environment_proof,
              'quality_carry_permitted':False,'fresh_fitness_measurement':False,
              'scope':'One cold JVM on fixed ABC scale input; no median, throughput, SLO, hard RAM cap or worst-case claim. Original captures retain original SHA/length while explicitly projected protocol/metadata are separately bound. Private pre-GO ownership is not replayed; its pinned actual private review is a separate gate. Collector/outer closure, original-to-public transformation and pre-GO inventories require separate independent review.'}
    with a.output.open('x', encoding='utf-8', newline='\n') as f:
        json.dump(output, f, ensure_ascii=True, indent=2); f.write('\n')


if __name__ == '__main__':
    main()
