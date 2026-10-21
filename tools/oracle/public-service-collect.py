"""Collect closed actual public-service cases and preserve every frozen mismatch."""
import argparse
import hashlib
import json
import struct
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def fields_different(left, right, path=''):
    if type(left) is not type(right):
        return [path or '/']
    if isinstance(left, dict):
        out = []
        for key in sorted(set(left) | set(right)):
            p = path + '/' + key
            out += [p] if key not in left or key not in right else fields_different(left[key], right[key], p)
        return out
    if isinstance(left, list):
        if len(left) != len(right):
            return [path + '/length']
        return [p for index, (a, b) in enumerate(zip(left, right)) for p in fields_different(a, b, path + '/' + str(index))]
    if isinstance(left, float):
        return [] if struct.pack('>d', left) == struct.pack('>d', right) else [path or '/']
    return [] if left == right else [path or '/']


parser = argparse.ArgumentParser()
parser.add_argument('--plan', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
plan = read(args.plan)
rows = []
for case in plan['cases']:
    config = read(Path(case['config']))
    assert sha(Path(case['config'])).upper() == case['config_sha256'].upper()
    native_dir = Path(config['output_directory'])
    records = []
    for label, name in [('worker', 'worker.process.json'), ('child', 'child.process.json')]:
        process = read(native_dir / name)
        assert process['native_exit'] == 0 and process['stdout_complete'] and process['stderr_complete']
        assert not process['output_limit'] and not process['capture_fault'] and not process['drain_timeout']
        for stream in ['stdout', 'stderr']:
            path = native_dir / (label + '.' + stream)
            assert sha(path).upper() == process[stream + '_sha256'].upper()
            assert path.stat().st_size == process[stream + '_bytes_persisted']
        records.append({'path': str(native_dir / name), 'sha256': sha(native_dir / name)})
    observed_path = Path(case['observation'])
    observed = read(observed_path)
    assert observed['id'] == case['id'] and observed['input_sha256'].lower() == case['fixture_sha256'].lower()
    assert observed['corpus_sha256'].lower() == case['corpus_sha256'].lower()
    expected = observed['parameters']['expected_source_hypothesis']
    before, after = observed['before'], observed['after']
    checks = {'outcome': observed['outcome'] == expected['outcome'],
              'actual_transaction_active': bool(observed['transaction_entries']) and all(entry['actual_transaction_active'] and entry['synchronization_active'] for entry in observed['transaction_entries']),
              'actual_original_service': observed['service_identity']['sha256'] == '24900e3f31629f3337490b930d51fbe7b4c1436872ed184477ae580a17d61097',
              'reopened_database_equal': observed['reopened_before_read']['database'] == after['database'],
              'reopened_files_equal': observed['reopened_after_read']['files'] == after['files'],
              'reopened_cache_initially_empty': observed['reopened_before_read']['cache'] == []}
    deltas = {key: after['database'][key] - before['database'][key] for key in before['database']}
    deltas.update(files=len(after['files']) - len(before['files']), cache=len(after['cache']) - len(before['cache']))
    for expected_key, actual_key in [('log_delta', 'logs'), ('storage_delta', 'storage'), ('file_delta', 'files'), ('cache_delta', 'cache')]:
        if expected_key in expected:
            checks[expected_key] = deltas[actual_key] == expected[expected_key]
    if expected.get('file_delta') == 0:
        checks['files_exactly_unchanged'] = before['files'] == after['files']
    if expected.get('cache_delta') == 0:
        checks['cache_exactly_unchanged'] = before['cache'] == after['cache']
    if 'exception_class' in expected:
        checks['exception_class'] = observed.get('exception', {}).get('chain', [{}])[0].get('class') == expected['exception_class']
    if 'exception_message' in expected:
        checks['exception_message'] = observed.get('exception', {}).get('chain', [{}])[0].get('message') == expected['exception_message']
    differences = []
    if 'first_readback' in observed:
        saved = observed['first_readback']
        typed = saved['reloaded_log']
        checks['durable_reload_available'] = observed['reopened_readback']['reloaded_log'] is not None
        if 'folder' in expected:
            folder = None if expected['folder'] == 'home' else observed['seed_folder_ids'][expected['folder']]
            checks['folder'] = saved['folder_id'] == folder
        if 'rights' in expected:
            actual = {r['group_name']: [r['read'], r['write'], r['owner']] for r in saved['rights']}
            checks['rights'] = actual == expected['rights']
        if 'normalized_name' in expected:
            checks['normalized_name'] = saved['name'] == expected['normalized_name']
        for key, actual in [('stored_traces', typed['trace_count']), ('stored_events', typed['event_count'])]:
            if key in expected:
                checks[key] = actual == expected[key]
        event_attrs = [event['attributes'] for trace in typed['traces'] for event in trace['events']]
        for key, attr in [('stored_activities', 'concept:name'), ('stored_timestamp_millis', 'time:timestamp'), ('stored_lifecycle', 'lifecycle:transition')]:
            if key in expected:
                values = [next(a['value'] for a in attrs if a['key'] == attr) for attrs in event_attrs]
                checks[key] = values == expected[key]
        if expected.get('apm_cache') == 'absent for empty converted log':
            checks['apm_cache'] = saved['apm_cache_class'] is None
        if 'wide_integers' in expected:
            attrs = {a['key']: a for a in typed['attributes']}
            attrs.update({a['key']: a for values in event_attrs for a in values})
            exact = {'budget': 9007199254740993, 'long-max': 9223372036854775807,
                     'long-min': -9223372036854775808, 'wide-negative': -9007199254740993}
            checks['wide_integers'] = all(attrs.get(key, {}).get('type') == 'int' and type(attrs[key]['value']) is int
                                         and attrs[key]['value'] == value for key, value in exact.items())
            checks['negative_zero'] = attrs['negative-zero']['type'] == 'float' and struct.pack('>d', attrs['negative-zero']['value']) == struct.pack('>d', -0.0)
            checks['uuid'] = attrs['uuid']['type'] == 'id' and attrs['uuid']['value'].lower() == '00112233-4455-6677-8899-aabbccddeeff'
        if expected.get('classifiers') == 'exact name and key order':
            checks['classifiers'] = typed['classifiers'] == [{'name': 'Activity resource', 'keys': ['concept:name', 'resource']}]
        if expected.get('extensions') == 'known concept/time/lifecycle exact':
            checks['extensions'] = typed['extensions'] == [
                {'name': 'Concept', 'prefix': 'concept', 'uri': 'http://www.xes-standard.org/concept.xesext'},
                {'name': 'Lifecycle', 'prefix': 'lifecycle', 'uri': 'http://www.xes-standard.org/lifecycle.xesext'},
                {'name': 'Time', 'prefix': 'time', 'uri': 'http://www.xes-standard.org/time.xesext'}]
        if expected.get('global_attributes') == 'absent':
            checks['global_attributes'] = typed['global_trace_attributes'] == [] and typed['global_event_attributes'] == []
        if observed['parameters']['file'] == 'typed-defaults.xes':
            attrs = {a['key']: a for a in typed['attributes']}
            event = {a['key']: a for a in event_attrs[0]}
            trace = {a['key']: a for a in typed['traces'][0]['attributes']}
            checks['default_xlog_name'] = attrs['concept:name'] == {'key': 'concept:name', 'type': 'string', 'value': 'Anonymous log imported from '}
            checks['default_lifecycle'] = event['lifecycle:transition'] == {'key': 'lifecycle:transition', 'type': 'string', 'value': 'complete'}
            checks['custom_flat_types'] = attrs['department']['type'] == 'string' and attrs['department']['value'] == 'synthetic' and trace['weight']['type'] == 'float' and trace['weight']['value'] == 1.5 and event['cost']['type'] == 'int' and event['cost']['value'] == 7 and event['approved']['type'] == 'boolean' and event['approved']['value'] is True
            checks['classifiers'] = typed['classifiers'] == [{'name': 'Activity lifecycle', 'keys': ['concept:name', 'lifecycle:transition']}]
            checks['global_metadata_not_materialized'] = typed['global_event_attributes'] == [{'key': 'resource', 'type': 'string', 'value': 'global-default'}] and 'resource' not in event
            checks['timestamp_millisecond_precision'] = event['time:timestamp']['type'] == 'date' and event['time:timestamp']['value'] == 1704067200123
        differences = fields_different(saved['reloaded_log'], observed['reopened_readback']['reloaded_log'])
        if expected.get('reopened_typed_log') == 'equal initial full typed log':
            checks['reopened_full_typed_equal'] = not differences
    checked_expected = {'outcome', 'folder', 'rights', 'normalized_name', 'log_delta', 'storage_delta', 'file_delta', 'cache_delta',
                        'exception_class', 'exception_message', 'stored_traces', 'stored_events', 'stored_activities',
                        'stored_timestamp_millis', 'stored_lifecycle', 'apm_cache', 'wide_integers', 'negative_zero', 'uuid',
                        'classifiers', 'extensions', 'global_attributes', 'reopened_typed_log'}
    descriptive_expected = {'external_effects', 'date_precision'}
    pending = sorted(set(expected) - checked_expected - descriptive_expected)
    row = {'id': case['id'], 'input_sha256': observed['input_sha256'], 'observation': observed,
           'observation_sha256': sha(observed_path), 'native': {'path': str(native_dir), 'records': records},
           'observer_execution_pins': [pin for pin in config['inputs'] if pin['path'].endswith(('.java', '.class'))],
           'adapter_generation': case.get('adapter_generation', 'recorded_by_exact_config'),
           'frozen_manual_expected_checks': checks, 'actual_deltas': deltas,
           'initial_vs_reopened_typed_difference_paths': differences,
           'pending_manual_expected_fields': pending,
           'external_effects_are_observed_not_atomicity_claim': 'external_effects' in expected}
    rows.append(row)
result = {'schema_version': 1, 'status': 'ACTUAL_PUBLIC_PATH_FINITE_CORPUS_OBSERVED',
          'plan_sha256': sha(args.plan), 'collector_source_sha256': sha(Path(__file__)),
          'source_aware_carry': plan.get('source_aware_carry'),
          'case_count': len(rows), 'all_frozen_checked_fields_match': all(all(r['frozen_manual_expected_checks'].values()) and not r['pending_manual_expected_fields'] for r in rows),
          'cases': rows,
          'limitations': ['Selective real reachable public username/perspective=false path, explicit unwired unreachable services',
                          'No Portal/HTTP authentication or production MySQL claim',
                          'Actual default-name whitespace change on gzip/reparse is preserved, not normalized',
                          'DB rollback does not imply filesystem/cache rollback', 'No whole original R2 or enterprise parity claim']}
with args.out.open('x', encoding='utf-8') as output:
    json.dump(result, output, indent=2, ensure_ascii=False, allow_nan=False)
    output.write('\n')
print(json.dumps({'status': result['status'], 'cases': len(rows),
                  'all_frozen_checked_fields_match': result['all_frozen_checked_fields_match'],
                  'sha256': sha(args.out)}))
