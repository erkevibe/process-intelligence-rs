"""Audit the fixed public saved observations; never starts a product or database."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import types


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def sha(raw):
    return hashlib.sha256(raw).hexdigest().upper()


def full_capture(record, inner):
    need(type(record['native_exit']) is int, 'native_exit_known')
    if inner:
        need(record['source_status'] == 'captured', 'capture_source_status')
        for side in ('stdout', 'stderr'):
            need(record[side + '_eof'] is True and record[side + '_truncated'] is False and
                 record[side + '_fault'] is False, 'inner_capture_flags')
    else:
        need(record['output_limit'] is False and record['capture_fault'] is False, 'outer_capture_flags')
    for flag in ('drain_timeout', 'output_limit', 'capture_fault'):
        need(record.get(flag, False) is False, 'capture_fault_flag')
    for side in ('stdout', 'stderr'):
        need(type(record[side + '_bytes_persisted']) is int and
             record[side + '_bytes_persisted'] >= 0, 'capture_byte_counter_type')
        need(record[side + '_complete'] is True and
             record.get(side + '_truncated', False) is False and
             record.get(side + '_fault', False) is False and
             record.get(side + '_eof', True) is True, 'capture_not_full')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    validator = root / 'tools/sprint20/verify-evidence-manifest.py'
    need(sha(validator.read_bytes()) == '7C1FDA428A2DB0E7F89D6DBD04277B9AA3FEC0955CA43CCBEAD43A4D5A679FA9', 'manifest_validator_pin')
    inventory = runpy.run_path(str(validator))['verify'](args.evidence)
    manifest = json.loads((args.evidence / 'manifest.json').read_bytes())
    rows = {r['path']: r for r in manifest['files']}
    helper = root / 'tools/sprint24/current-api-http.py'
    need(sha(helper.read_bytes()) == '9D870DF8B9FF3D74595596A414B6F6D9BB07A97A33149BF891507C7533571448', 'observer_pin')
    module = types.ModuleType('saved_observer')
    module.__file__ = str(helper)
    exec(compile(helper.read_bytes(), str(helper), 'exec'), module.__dict__)
    expected = {'api/http-pre': (231, 214), 'api/http-post': (7, 5),
                'operations/http-seed': (11, 5), 'operations/http-lease-check': (4, 6),
                'operations/http-down': (3, 4), 'operations/http-latched': (3, 4),
                'operations/http-restored': (4, 6)}
    requests = checks = 0
    for name, counts in expected.items():
        directory = args.evidence / name
        proof = json.loads((directory / 'proof.json').read_bytes())
        need(proof['status'] == ('ACTUAL_CURRENT_API_PASS' if name.startswith('api/')
                                 else 'ACTUAL_S24_OPERATIONS_HTTP_PASS'), 'proof_status')
        need(len(proof['requests']) == counts[0] and len(proof['checks']) == counts[1], 'finite_profile_count')
        probe = module.Probe(None, directory)
        probe.rows, probe.checks = proof['requests'], proof['checks']
        probe.reconcile()
        for i, row in enumerate(probe.rows):
            need(type(row['id']) is int and row['id'] == i and
                 type(row['status']) is int and row['status'] == row['expected_status'] and
                 row['status_assertion'] == 'passed', 'saved_status')
        requests += counts[0]
        checks += counts[1]
    exit_maps = {
        'api': dict.fromkeys(('child', 'http90k', 'pg-stop', 'postgres', 'ready-02',
                             'source10k', 'source90k', 'worker', 'collector', 'launch'), 0),
        'operations': dict.fromkeys(('http-lease-check', 'http-latched', 'snapshot-before',
                       'http-restored', 'cluster-g2', 'ready-g1-02', 'cluster-g1', 'postgres-g1',
                       'pg-stop-g2', 'snapshot-after', 'snapshot-lease', 'create-db', 'http-seed',
                       'worker', 'postgres-g2', 'pg-stop-g1', 'ready-g2-02', 'http-down',
                       'collector', 'launch'), 0)}
    exit_maps['api'].update({'app10k': 137, 'app90k': 137, 'ready-01': 1})
    exit_maps['operations'].update({'app-duplicate': 1, 'app-live': 137, 'app-restarted': 137,
                                    'ready-g1-01': 1, 'ready-g2-01': 1})
    records = 0
    for profile, expected_count in [('api', 13), ('operations', 25)]:
        files = list((args.evidence / profile).rglob('*.process.json'))
        need(len(files) == expected_count and
             {p.name.removesuffix('.process.json') for p in files} == set(exit_maps[profile]), 'native_profile_count')
        for file in files:
            descriptor = json.loads(file.read_bytes())
            full_capture(descriptor, file.parent.name == 'session')
            need(descriptor['native_exit'] == exit_maps[profile][file.name.removesuffix('.process.json')], 'native_profile_exit')
            for side in ('stdout', 'stderr'):
                stream = file.with_name(file.name.replace('.process.json', '.' + side))
                identity = rows[stream.relative_to(args.evidence).as_posix()]
                need(type(identity['original_bytes']) is int and identity['original_bytes'] >= 0 and
                     descriptor[side + '_bytes_persisted'] == identity['original_bytes'] and
                     descriptor[side + '_sha256'].upper() == identity['original_sha256'].upper(),
                     'original_capture_identity')
            records += 1
        broker = json.loads((args.evidence / profile / 'session/broker-result.json').read_bytes())
        need(broker['failure'] is None and broker['guard_failure'] is None and
             broker['primary_exception'] is None and
             broker['kill_fault'] is False and broker['absolute_stop_timer_fired'] is False and
             broker['stop_reason'] == 'worker_exit' and not broker['secondary_diagnostics'], 'saved_broker_failure')
    snapshots = [args.evidence / 'operations/session' / ('snapshot-' + x + '.stdout')
                 for x in ('before', 'lease', 'after')]
    need(len({p.read_bytes() for p in snapshots}) == 1, 'business_snapshots_differ')
    for generation in ('g1', 'g2'):
        stop = json.loads((args.evidence / 'operations/session' /
                           ('postgres-' + generation + '-stop-transaction.json')).read_bytes())
        need(stop['pid_absent'] is True and stop['both_full_eof'] is True and
             stop['scanner_unchanged'] is True and stop['stop_window_seconds'] == 19, 'saved_stop_transaction')
    capacity = args.evidence / 'capacity'
    need(capacity.is_dir(), 'capacity_selection_required')
    positive = (capacity / 'session/app10k.stdout').read_text(encoding='utf-8').splitlines()
    need(len(positive) == 2 and positive[1] == 'CAPACITY_DIAGNOSTIC_COMMITTED_V1', 'capacity_completion')
    report = json.loads(positive[0])
    need(type(report['schema_version']) is int and report['schema_version'] == 1 and
         report['transaction_read_only'] == 'on' and report['transaction_isolation'] == 'repeatable read' and
         type(report['project_count']) is int and report['project_count'] == 1 and
         module.same(report['record_counts'], {'log_state': 1, 'log_data': 1, 'log_source': 1,
                     'log_analysis': 1, 'model': 0, 'conversion': 0}), 'capacity_manual_counts')
    need(type(report['database_physical_bytes']) is int and report['database_physical_bytes'] >= 0 and
         len(report['managed_relations']) == 5 and
         {r['relation'] for r in report['managed_relations']} ==
         {'pi_kv', 'pi_schema_migrations', 'pi_projects', 'pi_records', 'pi_migration_v2'}, 'capacity_physical_scope')
    for relation in report['managed_relations']:
        for key in ('table_including_toast_bytes', 'indexes_bytes', 'total_bytes'):
            need(type(relation[key]) is int and relation[key] >= 0, 'capacity_size_integer')
    for label, code, reason in [('app90k', '25006', 'read-only transaction'),
                                ('empty-report', '22023', 'capacity_minimum_v3_schema_required'),
                                ('unknown-report', '22023', 'capacity_unknown_record_kind'),
                                ('http90k', '55P03', 'lock timeout')]:
        record = json.loads((capacity / 'session' / (label + '.process.json')).read_bytes())
        error = (capacity / 'session' / (label + '.stderr')).read_text(encoding='utf-8')
        output = (capacity / 'session' / (label + '.stdout')).read_text(encoding='utf-8')
        need(record['native_exit'] == 3 and code in error and reason in error and
             'CAPACITY_DIAGNOSTIC_COMMITTED_V1' not in output, 'capacity_negative')
    sentinel = json.loads((capacity / 'session/source90k.stdout').read_bytes())
    need(module.same(sentinel, {'rows': 1, 'minimum': 17, 'maximum': 17}), 'capacity_sentinel')
    capacity_records = list(capacity.rglob('*.process.json'))
    capacity_exits = {name: 0 for name in ('app10k', 'child', 'create-control', 'create-empty',
                      'lock-ready-01', 'pg-stop', 'postgres', 'ready-02', 'setup-control',
                      'source10k', 'source90k', 'worker', 'collector', 'launch')}
    capacity_exits.update({'app90k': 3, 'empty-report': 3, 'http90k': 3, 'unknown-report': 3, 'ready-01': 1})
    need(len(capacity_records) == 19 and
         {p.name.removesuffix('.process.json') for p in capacity_records} == set(capacity_exits), 'capacity_native_inventory')
    for file in capacity_records:
        descriptor = json.loads(file.read_bytes())
        full_capture(descriptor, file.parent.name == 'session')
        need(descriptor['native_exit'] == capacity_exits[file.name.removesuffix('.process.json')], 'capacity_native_exit')
        for side in ('stdout', 'stderr'):
            stream = file.with_name(file.name.replace('.process.json', '.' + side))
            identity = rows[stream.relative_to(args.evidence).as_posix()]
            need(descriptor[side + '_complete'] is True and
                 type(identity['original_bytes']) is int and identity['original_bytes'] >= 0 and
                 descriptor[side + '_bytes_persisted'] == identity['original_bytes'] and
                 descriptor[side + '_sha256'].upper() == identity['original_sha256'].upper(), 'capacity_capture_identity')
    capacity_broker = json.loads((capacity / 'session/broker-result.json').read_bytes())
    need(capacity_broker['failure'] is None and capacity_broker['guard_failure'] is None and
         capacity_broker['primary_exception'] is None and
         capacity_broker['kill_fault'] is False and capacity_broker['absolute_stop_timer_fired'] is False and
         capacity_broker['stop_reason'] == 'worker_exit' and not capacity_broker['secondary_diagnostics'], 'capacity_broker_failure')
    capacity_phase = json.loads((capacity / 'capacity-phase-proof.json').read_bytes())
    need(capacity_phase['pid_absent'] is True and capacity_phase['apps_started'] is False and
         capacity_phase['production_report_readonly'] is True, 'capacity_phase_closure')
    need((capacity / 'session/lock-ready-01.stdout').read_text(encoding='utf-8').strip() ==
         'CAPACITY_LOCK_HELD_V1' and 'LOCK_HOLDER_ACQUIRED' in
         (capacity / 'session/child.stdout').read_text(encoding='utf-8'), 'capacity_granted_lock_marker')
    need(len((capacity / 'session/app10k.stdout').read_bytes()) <= 16384, 'capacity_report_bound')
    print(json.dumps({'status': 'SAVED_SCOPED_CONSISTENCY_PASS_NOT_FRESH_EXECUTION',
                      'inventory': inventory, 'http_requests': requests, 'checks': checks,
                      'api_operations_native_records': records, 'api_operations_raw_capture_slots': records * 2,
                      'capacity_native_records': len(capacity_records),
                      'limits': 'Path-projected files have separate hashes. This audit does not repeat product assertions, prove physical power-loss safety, HA, SLO or enterprise readiness.'}))


if __name__ == '__main__':
    main()
