#!/usr/bin/env python3
"""Portable consistency and synthetic accounting checks, not SQL/service replay."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


TOOLS = Path(__file__).resolve().parents[1]
previous = module('s32_checker', TOOLS / 'sprint32/verify-offline-evidence.py')
audit = module('s30_accounting', TOOLS / 'sprint30/audit-quota.py')
load, sha = previous.s31.load, previous.s31.sha
RAW_FILES = {'accounting-proof.json', 'recount-records.json', 'recount-quota.json', 'recount-projects.json'}
FILES = {'proof.json', 'base-profile-proof.json', 'offline-proof.json', 'systemd-package-verification.json', 'provenance.json'} | RAW_FILES
CASES = {
    'third_owned_database_absent_before_changes',
    'fresh_clone_matches_quiescent_source_before_fixture_reconstruction',
    'non_superuser_database_role_owns_all_restored_tables_and_sequence',
    'synthetic_v5_exact_ledger_schema_and_all_data_match_only_declared_differences',
    'file_credential_CLI_really_creates_v6_DDL_under_non_superuser_and_preserves_v5_projection',
    'independent_recount_matches_every_project_counter_and_record_version_cost',
    'second_offline_CLI_is_exact_v6_noop_after_real_upgrade',
    'new_service_reads_migrated_report_and_grants_with_default_off_quota_and_unchanged_source',
    'known_fixture_secrets_not_in_service_or_migration_journals',
    'all_services_stopped_and_original_credential_target_restored_without_source_writes',
}


def cli(value):
    assert type(value['wrapper_native_exit']) is int and value['wrapper_native_exit'] == 0
    assert value['process_proc_identity_observed'] is False
    assert value['normalized_refusal_reason'] is value['refusal_journal_source'] is None
    binding = value['credential_binding']
    unit = binding['unit']
    assert unit in ('pi-s32-migrate-repeat.service', 'pi-s32-migrate-refuse.service')
    encoded = ''.join(char if char.isascii() and char.isalnum() else '_' + format(ord(char), '02x') for char in unit)
    assert binding == dict(unit=unit, object_path='/org/freedesktop/systemd1/unit/' + encoded,
        property=dict(type='a(ss)', data=[['database-url', '/etc/process-intelligence/database-url']]))
    props = value['configured_unit_properties']
    assert props['LoadState'] == 'loaded' and props['Transient'] == props['RemainAfterExit'] == 'yes'
    assert props['Type'] == 'oneshot' and props['Restart'] == 'no' and props['SuccessExitStatus'] == ''
    assert props['User'] == props['Group'] == 'process-intelligence'
    assert props['WorkingDirectory'] == '/opt/process-intelligence/current'
    assert props['Environment'] == 'PI_DATABASE_URL_FILE=/run/credentials/' + unit + '/database-url'
    assert set(props['UnsetEnvironment'].split()) == {'PI_DATABASE_URL', 'PI_EPHEMERAL'}
    assert props['NoNewPrivileges'] == 'yes' and props['ProtectSystem'] == 'strict'
    assert props['FragmentPath'] == '/run/systemd/transient/' + unit
    assert props['MainPID'] == props['ExecMainStatus'] == '0' and int(props['ExecMainPID']) > 1 and props['ExecMainCode'] == '1'
    assert props['Result'] == 'success' and props['ActiveState'] == 'active' and props['SubState'] == 'exited'
    assert 'argv[]=/opt/process-intelligence/current/process-intelligence-rs --migrate-storage ;' in props['ExecStart'] and 'ignore_errors=no' in props['ExecStart']
    assert value['retired']['MainPID'] == '0' and value['retired']['ActiveState'] == 'inactive'
    assert value['retired']['LoadState'] in ('loaded', 'not-found')


def derive_accounting(records, quotas, projects):
    assert isinstance(records, list) and isinstance(quotas, list) and isinstance(projects, list)
    assert len(projects) == len(set(projects)) and projects and [row['project_id'] for row in quotas] == projects
    for row in records:
        assert set(row) == {'project', 'kind', 'id', 'version', 'document'} and row['project'] in projects
        assert row['kind'] in audit.KINDS and isinstance(row['id'], str) and row['id']
        assert type(row['version']) is int and row['version'] > 0
    snapshots = []
    for quota in quotas:
        assert set(quota) == {'project_id', 'metric_version', 'payload_used', 'record_costs'}
        assert type(quota['metric_version']) is int and quota['metric_version'] == 1
        assert type(quota['payload_used']) is int and quota['payload_used'] >= 0
        assert isinstance(quota['record_costs'], dict)
        for group in quota['record_costs'].values():
            assert isinstance(group, dict)
            for entry in group.values():
                assert set(entry) == {'version', 'cost'} and type(entry['version']) is int and entry['version'] > 0
                assert type(entry['cost']) is int and entry['cost'] > 0
        ledger, used = {}, 0
        selected = [row for row in records if row['project'] == quota['project_id']]
        for row in selected:
            cost = 32 + len(row['kind'].encode()) + len(row['id'].encode()) + audit.cost(row['document'])
            group = ledger.setdefault(row['kind'], {})
            assert row['id'] not in group
            group[row['id']] = dict(version=row['version'], cost=cost)
            used += cost
        assert quota['payload_used'] == used and quota['record_costs'] == ledger
        snapshots.append(dict(name=quota['project_id'], payload_used=used,
            records=[{key: row[key] for key in ('kind', 'id', 'document')} for row in selected]))
    return dict(schema_version=1, metric='structural_bytes_v1', header_reserve=268369920, snapshots=snapshots)


def verify_core(proof, base, earlier, raw, package):
    previous.verify_core(earlier, base, package)
    assert proof['status'] == 'S33_NON_SUPERUSER_V5_CLI_UPGRADE_PASS' and proof['source_commit'] == base['source_commit']
    assert len(proof['cases']) == len(CASES) and {row['case'] for row in proof['cases']} == CASES
    assert all(set(row) == {'case', 'outcome'} and row['outcome'] == 'pass' for row in proof['cases'])
    role = proof['role']
    assert set(role) == {'database_owner', 'superuser', 'createdb', 'createrole', 'foreign_public_owners'}
    assert role['database_owner'] == 'pi_s31_app' and type(role['foreign_public_owners']) is int and role['foreign_public_owners'] == 0
    assert all(role[key] is False for key in ('superuser', 'createdb', 'createrole'))
    cli(proof['upgrade'])
    cli(proof['repeat'])
    assert proof['upgrade']['configured_unit_properties']['ExecMainPID'] != proof['repeat']['configured_unit_properties']['ExecMainPID']
    source, old, new = (sha(proof[key]) for key in ('source_snapshot_sha256', 'v5_snapshot_sha256', 'v6_snapshot_sha256'))
    assert len({source, old, new}) == 3
    assert set(raw) == RAW_FILES
    def outputs(label):
        return [row['stdout_sha256'] for row in proof['commands'] if row['label'] == label]
    for label, name in [('s33-private-records-for-recount', 'recount-records.json'),
                        ('s33-private-quota-counters', 'recount-quota.json'), ('s33-project-ids', 'recount-projects.json')]:
        assert outputs(label) == [hashlib.sha256(raw[name]).hexdigest()]
    derived = derive_accounting(load(raw['recount-records.json']), load(raw['recount-quota.json']), load(raw['recount-projects.json']))
    assert derived == load(raw['accounting-proof.json'])
    assert hashlib.sha256(raw['accounting-proof.json']).hexdigest() == sha(proof['accounting_input_sha256'])
    accounting = audit.verify(derived)
    assert proof['independent_accounting_verification'] == accounting
    summaries = [dict(project_id=row['snapshot'], records=row['records'], payload_used=row['payload_used']) for row in accounting['snapshots']]
    assert proof['independent_accounting'] == summaries
    project = next(row['path'].split('/')[2] for row in base['requests'] if row['path'].startswith('/projects/'))
    assert proof['quota']['enabled'] is False and proof['quota']['metric'] == 'structural_bytes_v1'
    assert proof['quota']['payload_used'] == next(row['payload_used'] for row in summaries if row['project_id'] == project)
    assert proof['report_sha256'] == base['report_sha256']
    for name, app in [('app_after', True), ('proxy_after', False), ('app_stopped', True), ('proxy_stopped', False)]:
        row = proof[name]
        previous.s31.profile_identity(row, app)
        assert row['NRestarts'] == row['ExecMainStatus'] == '0' and row['Result'] == 'success'
        if name.endswith('_stopped'):
            assert row['ActiveState'] == 'inactive' and row['MainPID'] == '0'
        else:
            before = earlier['app_after' if app else 'proxy_after']
            assert row['ActiveState'] == 'active' and int(row['MainPID']) > 1 and row['MainPID'] != before['MainPID']
            assert int(row['ExecMainStartTimestampMonotonic']) > int(before['ExecMainStartTimestampMonotonic'])
            assert row['executable_sha256'] == before['executable_sha256']
            assert row['User'] == row['Group'] == ('process-intelligence' if app else 'caddy')
            if app:
                assert row['NoNewPrivileges'] == 'yes' and row['ProtectSystem'] == 'strict'
    contract = load(Path(__file__).with_name('upgrade-command-contract.json').read_bytes())
    assert type(contract['schema_version']) is int and contract['schema_version'] == 1
    assert len(proof['commands']) == len(contract['commands'])
    for row, expected in zip(proof['commands'], contract['commands']):
        assert set(row) == {'label', 'program', 'native_exit', 'stdout_sha256', 'stderr_sha256'}
        assert row['label'] == expected['label'] and row['program'] == expected['program']
        assert type(row['native_exit']) is int and row['native_exit'] == 0
        sha(row['stdout_sha256'])
        sha(row['stderr_sha256'])
    assert outputs('full-private-database-snapshot') == [source, source, source]
    assert outputs('s33-v5-snapshot') == [old]
    assert outputs('s33-v6-snapshot') == [source, new, new]
    assert outputs('s33-new-quota-table-owner') == [hashlib.sha256(b'pi_s31_app\n').hexdigest()]
    reports = {row['path'] for row in base['requests'] if row['path'].endswith('/report')}
    stable, actual_reports, actual_projects = [], set(), set()
    for row in proof['requests']:
        assert set(row) == {'method', 'path', 'status', 'content_type', 'bytes', 'sha256'}
        assert type(row['status']) is int and type(row['bytes']) is int and 0 <= row['bytes'] <= 4 * 1024 * 1024
        sha(row['sha256'])
        if row['path'] == '/health':
            assert row['method'] == 'GET' and row['status'] in (200, 502, 503)
            continue
        if row['path'].endswith('/report'):
            actual_reports.add(row['path'])
            assert row['sha256'] == proof['report_sha256']
        if row['path'].startswith('/projects/'):
            actual_projects.add(row['path'].split('/')[2])
        stable.append(row)
    assert actual_reports == reports and actual_projects == {project}
    assert len(stable) == len(contract['requests'])
    for row, expected in zip(stable, contract['requests']):
        assert row['method'] == expected['method'] and row['status'] == expected['status'] and re.fullmatch(expected['path_pattern'], row['path'])
    return accounting


def verify_values(data, raw):
    result = verify_core(data['proof.json'], data['base-profile-proof.json'], data['offline-proof.json'], raw, data['systemd-package-verification.json'])
    origin = data['provenance.json']
    assert origin['source_commit'] == data['proof.json']['source_commit']
    assert all(type(origin[key]) is int and origin[key] > 0 for key in ('run_id', 'job_id', 'artifact_id'))
    sha(origin['artifact_zip_sha256'])
    assert origin['scope'] == 'selected synthetic observations downloaded from GitHub Actions; no root replay or author authentication'
    return result


def verify(root):
    assert not root.is_symlink() and {p.name for p in root.iterdir()} == FILES | {'manifest.json'}
    manifest = load((root / 'manifest.json').read_bytes())
    assert set(manifest) == {'schema_version', 'files'} and type(manifest['schema_version']) is int and manifest['schema_version'] == 1
    assert len(manifest['files']) == len(FILES)
    data, raw = {}, {}
    for row in manifest['files']:
        assert set(row) == {'path', 'bytes', 'sha256'} and row['path'] in FILES and row['path'] not in data
        path = root / row['path']
        assert path.is_file() and not path.is_symlink()
        value = path.read_bytes()
        assert type(row['bytes']) is int and len(value) == row['bytes'] and hashlib.sha256(value).hexdigest() == sha(row['sha256'])
        data[row['path']] = load(value)
        if row['path'] in RAW_FILES:
            raw[row['path']] = value
    assert set(data) == FILES and set(raw) == RAW_FILES
    verify_values(data, raw)
    return data, raw


if __name__ == '__main__':
    if len(sys.argv) == 10 and sys.argv[1] == '--runtime':
        proof, base, earlier, package = (load(Path(path).read_bytes()) for path in sys.argv[2:6])
        raw = {name: Path(path).read_bytes() for name, path in zip(
            ['accounting-proof.json', 'recount-records.json', 'recount-quota.json', 'recount-projects.json'], sys.argv[6:10])}
        verify_core(proof, base, earlier, raw, package)
        print(json.dumps(dict(status='S33_LIVE_V5_UPGRADE_OBSERVATIONS_PASS', source_commit=proof['source_commit'], cases=len(CASES))))
        raise SystemExit(0)
    data, raw = verify(Path(sys.argv[1]))
    controls = 0
    if '--self-test' in sys.argv[2:]:
        for change in ('missing-case', 'superuser', 'failed-upgrade', 'equal-snapshots', 'changed-source-capture',
                       'foreign-binary', 'wrong-report', 'unsupported-proc', 'missing-command', 'wrong-credential', 'wrong-project', 'rehash-wrong-accounting', 'coherent-document-rehash'):
            changed, new_raw = copy.deepcopy(data), dict(raw)
            proof = changed['proof.json']
            if change == 'missing-case': proof['cases'] = []
            elif change == 'superuser': proof['role']['superuser'] = True
            elif change == 'failed-upgrade': proof['upgrade']['configured_unit_properties']['ExecMainStatus'] = '1'
            elif change == 'equal-snapshots': proof['v6_snapshot_sha256'] = proof['v5_snapshot_sha256']
            elif change == 'changed-source-capture': next(row for row in proof['commands'] if row['label'] == 'full-private-database-snapshot')['stdout_sha256'] = '0' * 64
            elif change == 'foreign-binary': proof['app_after']['executable_sha256'] = '0' * 64
            elif change == 'wrong-report': proof['report_sha256'] = '0' * 64
            elif change == 'unsupported-proc': proof['upgrade']['process_proc_identity_observed'] = True
            elif change == 'missing-command': proof['commands'].pop()
            elif change == 'wrong-credential': proof['upgrade']['credential_binding']['property']['data'][0][1] = '/etc/foreign'
            elif change == 'wrong-project':
                for row in proof['requests']:
                    if row['path'].startswith('/projects/'): row['path'] = re.sub('project-[0-9a-f]{32}', 'project-' + '0' * 32, row['path'])
            else:
                accounting = load(raw['accounting-proof.json'])
                if change == 'rehash-wrong-accounting':
                    accounting['snapshots'][0]['payload_used'] += 1
                else:
                    record = next(row for snap in accounting['snapshots'] for row in snap['records'])
                    record['document'] = dict(coherent_tamper=record['document'])
                    for snap in accounting['snapshots']:
                        snap['payload_used'] = sum(32 + len(row['kind'].encode()) + len(row['id'].encode()) + audit.cost(row['document']) for row in snap['records'])
                    result = audit.verify(accounting)
                    proof['independent_accounting_verification'] = result
                    proof['independent_accounting'] = [dict(project_id=row['snapshot'], records=row['records'], payload_used=row['payload_used']) for row in result['snapshots']]
                    project = next(row['path'].split('/')[2] for row in changed['base-profile-proof.json']['requests'] if row['path'].startswith('/projects/'))
                    proof['quota']['payload_used'] = next(row['payload_used'] for row in proof['independent_accounting'] if row['project_id'] == project)
                new_raw['accounting-proof.json'] = (json.dumps(accounting, indent=2) + '\n').encode()
                proof['accounting_input_sha256'] = hashlib.sha256(new_raw['accounting-proof.json']).hexdigest()
            try: verify_values(changed, new_raw)
            except AssertionError: controls += 1
            else: raise AssertionError('semantic alteration accepted: ' + change)
    print(json.dumps(dict(status='S33_SELECTED_V5_UPGRADE_EVIDENCE_PASS', source_commit=data['proof.json']['source_commit'],
        cases=len(CASES), semantic_refusal_controls=controls, scope='selected consistency and independent synthetic record accounting; no SQL/service replay or author authentication')))
