#!/usr/bin/env python3
"""Check selected offline migration observations, without executing services."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

spec = importlib.util.spec_from_file_location('s31_evidence', Path(__file__).resolve().parents[1] / 'sprint31/verify-service-evidence.py')
s31 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s31)
FILES = {'proof.json', 'base-profile-proof.json', 'systemd-package-verification.json', 'provenance.json'}
CASES = {
    'fixed_transient_unit_names_and_paths_are_absent',
    'offline_v6_repeat_through_LoadCredential_keeps_full_database_snapshot',
    'offline_CLI_checksum_refusal_exit1_keeps_corrupted_snapshot_unchanged',
    'explicit_owned_fixture_repair_restores_exact_pretest_snapshot',
    'new_service_process_preserves_report_quota_ledger_and_viewer_grant_after_offline_CLI',
    'offline_unit_journals_do_not_contain_fixture_secrets',
    'all_owned_services_and_transient_jobs_are_stopped_before_firewall_cleanup',
}
REFUSAL_MESSAGE_SHA = hashlib.sha256('Схема или сохранённые данные не поддерживаются. Исходные записи не изменены; проверьте состояние миграции.'.encode()).hexdigest()


def verify_core(proof, base, package):
    s31.verify_core(base, package)
    assert proof['status'] == 'S32_OFFLINE_CREDENTIAL_MIGRATION_PASS'
    assert proof['source_commit'] == base['source_commit']
    assert len(proof['cases']) == len(CASES) and {row['case'] for row in proof['cases']} == CASES
    assert all(set(row) == {'case', 'outcome'} and row['outcome'] == 'pass' for row in proof['cases'])
    before, bad = s31.sha(proof['baseline_snapshot_sha256']), s31.sha(proof['corrupted_snapshot_sha256'])
    assert before != bad
    for name, unit, expected in [('repeat', 'pi-s32-migrate-repeat.service', 0), ('refusal', 'pi-s32-migrate-refuse.service', 1)]:
        value = proof[name]
        assert set(value) == {'wrapper_native_exit', 'configured_unit_properties', 'credential_binding', 'normalized_refusal_reason', 'refusal_journal_source', 'retired', 'process_proc_identity_observed'}
        assert type(value['wrapper_native_exit']) is int and value['wrapper_native_exit'] == expected
        assert value['process_proc_identity_observed'] is False
        assert value['normalized_refusal_reason'] == ('schema_unsupported' if expected == 1 else None)
        props = value['configured_unit_properties']
        assert props['LoadState'] == 'loaded' and props['Transient'] == props['RemainAfterExit'] == 'yes'
        assert props['Type'] == 'oneshot' and props['Restart'] == 'no' and props['SuccessExitStatus'] == ''
        assert props['FragmentPath'] == '/run/systemd/transient/' + unit
        assert props['User'] == props['Group'] == 'process-intelligence'
        assert props['WorkingDirectory'] == '/opt/process-intelligence/current'
        encoded = ''.join(char if char.isascii() and char.isalnum() else '_' + format(ord(char), '02x') for char in unit)
        assert value['credential_binding'] == dict(unit=unit, object_path='/org/freedesktop/systemd1/unit/' + encoded,
            property=dict(type='a(ss)', data=[['database-url', '/etc/process-intelligence/database-url']]))
        assert props['Environment'] == 'PI_DATABASE_URL_FILE=/run/credentials/' + unit + '/database-url'
        assert set(props['UnsetEnvironment'].split()) == {'PI_DATABASE_URL', 'PI_EPHEMERAL'}
        assert props['NoNewPrivileges'] == 'yes' and props['ProtectSystem'] == 'strict'
        assert props['MainPID'] == '0' and int(props['ExecMainPID']) > 1 and props['ExecMainCode'] == '1'
        assert value['refusal_journal_source'] == (dict(unit=unit, pid=props['ExecMainPID'], matched_message_sha256=REFUSAL_MESSAGE_SHA) if expected == 1 else None)
        assert props['ExecMainStatus'] == str(expected)
        assert props['Result'] == ('success' if expected == 0 else 'exit-code')
        assert props['ActiveState'] == ('active' if expected == 0 else 'failed')
        assert props['SubState'] == ('exited' if expected == 0 else 'failed')
        assert 'argv[]=/opt/process-intelligence/current/process-intelligence-rs --migrate-storage ;' in props['ExecStart']
        assert 'ignore_errors=no' in props['ExecStart']
        retired = value['retired']
        assert retired['ActiveState'] == 'inactive' and retired['MainPID'] == '0' and retired['LoadState'] in ('loaded', 'not-found')
    assert proof['repeat']['configured_unit_properties']['ExecMainPID'] != proof['refusal']['configured_unit_properties']['ExecMainPID']
    for name, app in [('app_after', True), ('proxy_after', False), ('app_stopped', True), ('proxy_stopped', False)]:
        row = proof[name]
        s31.profile_identity(row, app)
        assert row['NRestarts'] == row['ExecMainStatus'] == '0' and row['Result'] == 'success'
        if name.endswith('_stopped'):
            assert row['ActiveState'] == 'inactive' and row['MainPID'] == '0'
        else:
            assert row['ActiveState'] == 'active' and int(row['MainPID']) > 1
            previous = base['app_after' if app else 'proxy_after']
            assert row['MainPID'] != previous['MainPID']
            assert int(row['ExecMainStartTimestampMonotonic']) > int(previous['ExecMainStartTimestampMonotonic'])
            assert row['executable_sha256'] == previous['executable_sha256']
            assert row['User'] == row['Group'] == ('process-intelligence' if app else 'caddy')
            if app:
                assert row['NoNewPrivileges'] == 'yes' and row['ProtectSystem'] == 'strict'
    contract = s31.load(Path(__file__).with_name('offline-command-contract.json').read_bytes())
    assert set(contract) == {'schema_version', 'scope', 'commands', 'requests'}
    assert type(contract['schema_version']) is int and contract['schema_version'] == 1
    assert len(proof['commands']) == len(contract['commands'])
    for row, expected in zip(proof['commands'], contract['commands']):
        assert set(row) == {'label', 'program', 'native_exit', 'stdout_sha256', 'stderr_sha256'}
        assert row['label'] == expected['label'] and row['program'] == expected['program']
        assert type(row['native_exit']) is int and row['native_exit'] in expected['allowed_exits']
        s31.sha(row['stdout_sha256'])
        s31.sha(row['stderr_sha256'])
    snapshots = [row['stdout_sha256'] for row in proof['commands'] if row['label'] == 'full-private-database-snapshot']
    assert snapshots == [before, before, bad, bad, before]
    stable = []
    reports, projects = set(), set()
    base_reports = {row['path'] for row in base['requests'] if row['path'].endswith('/report')}
    base_projects = {row['path'].split('/')[2] for row in base['requests'] if row['path'].startswith('/projects/')}
    for row in proof['requests']:
        assert set(row) == {'method', 'path', 'status', 'content_type', 'bytes', 'sha256'}
        assert type(row['status']) is int and type(row['bytes']) is int and 0 <= row['bytes'] <= 4 * 1024 * 1024
        assert row['method'] in ('GET', 'POST') and isinstance(row['content_type'], str)
        s31.sha(row['sha256'])
        if row['path'] == '/health':
            assert row['method'] == 'GET' and row['status'] in (200, 502, 503)
            continue
        if row['path'].endswith('/report'):
            reports.add(row['path'])
            assert row['sha256'] == base['report_sha256']
        if row['path'].startswith('/projects/'):
            projects.add(row['path'].split('/')[2])
        if row['path'] == '/backup':
            assert row['sha256'] == base['project_backup_sha256']
        stable.append(row)
    assert reports == base_reports and projects == base_projects and len(reports) == len(projects) == 1
    assert len(stable) == len(contract['requests'])
    for row, expected in zip(stable, contract['requests']):
        assert row['method'] == expected['method'] and row['status'] == expected['status']
        assert re.fullmatch(expected['path_pattern'], row['path'])


def verify_values(data):
    verify_core(data['proof.json'], data['base-profile-proof.json'], data['systemd-package-verification.json'])
    origin = data['provenance.json']
    assert origin['source_commit'] == data['proof.json']['source_commit']
    for name in ['run_id', 'job_id', 'artifact_id']:
        assert type(origin[name]) is int and origin[name] > 0
    s31.sha(origin['artifact_zip_sha256'])
    assert origin['scope'] == 'selected observations downloaded from GitHub Actions; integrity checks do not replay services or authenticate authorship'


def verify(root):
    assert not root.is_symlink() and {p.name for p in root.iterdir()} == FILES | {'manifest.json'}
    manifest = s31.load((root / 'manifest.json').read_bytes())
    assert set(manifest) == {'schema_version', 'files'} and type(manifest['schema_version']) is int and manifest['schema_version'] == 1
    assert len(manifest['files']) == len(FILES)
    data = {}
    for row in manifest['files']:
        assert set(row) == {'path', 'bytes', 'sha256'} and row['path'] in FILES and row['path'] not in data
        path = root / row['path']
        assert path.is_file() and not path.is_symlink()
        raw = path.read_bytes()
        assert type(row['bytes']) is int and len(raw) == row['bytes']
        assert hashlib.sha256(raw).hexdigest() == s31.sha(row['sha256'])
        data[row['path']] = s31.load(raw)
    assert set(data) == FILES
    verify_values(data)
    return data


if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == '--runtime':
        proof, base, package = (s31.load(Path(path).read_bytes()) for path in sys.argv[2:])
        verify_core(proof, base, package)
        print(json.dumps(dict(status='S32_LIVE_OFFLINE_OBSERVATIONS_PASS', source_commit=proof['source_commit'], cases=len(CASES),
            scope='fresh observation consistency; no artifact download, root execution replay or author authentication claimed')))
        raise SystemExit(0)
    data = verify(Path(sys.argv[1]))
    controls = 0
    if '--self-test' in sys.argv[2:]:
        for change in ['missing-cases', 'masked-refusal', 'equal-snapshots', 'altered-snapshot-command',
                       'foreign-app', 'unsupported-proc-claim', 'missing-command', 'boolean-exit', 'ignored-failure', 'missing-report',
                       'wrong-report-id', 'wrong-project-id', 'wrong-credential-source', 'wrong-refusal-reason']:
            changed = copy.deepcopy(data)
            proof = changed['proof.json']
            if change == 'missing-cases':
                proof['cases'] = []
            elif change == 'masked-refusal':
                proof['refusal']['configured_unit_properties']['ExecMainStatus'] = '0'
            elif change == 'equal-snapshots':
                proof['corrupted_snapshot_sha256'] = proof['baseline_snapshot_sha256']
            elif change == 'altered-snapshot-command':
                next(row for row in proof['commands'] if row['label'] == 'full-private-database-snapshot')['stdout_sha256'] = '0' * 64
            elif change == 'foreign-app':
                proof['app_after']['executable_sha256'] = '0' * 64
            elif change == 'unsupported-proc-claim':
                proof['repeat']['process_proc_identity_observed'] = True
            elif change == 'missing-command':
                proof['commands'].pop()
            elif change == 'boolean-exit':
                proof['commands'][0]['native_exit'] = False
            elif change == 'ignored-failure':
                proof['refusal']['configured_unit_properties']['SuccessExitStatus'] = '1'
            elif change == 'missing-report':
                proof['requests'] = [row for row in proof['requests'] if not row['path'].endswith('/report')]
            elif change == 'wrong-report-id':
                for row in proof['requests']:
                    if row['path'].endswith('/report'):
                        row['path'] = '/quality/jobs/job-999/report'
            elif change == 'wrong-project-id':
                for row in proof['requests']:
                    if row['path'].startswith('/projects/'):
                        row['path'] = re.sub('project-[0-9a-f]{32}', 'project-' + '0' * 32, row['path'])
            elif change == 'wrong-credential-source':
                proof['repeat']['credential_binding']['property']['data'][0][1] = '/etc/process-intelligence/foreign-source'
            else:
                proof['refusal']['normalized_refusal_reason'] = 'storage_unavailable'
            try:
                verify_values(changed)
            except AssertionError:
                controls += 1
            else:
                raise AssertionError('semantic alteration accepted: ' + change)
    print(json.dumps(dict(status='S32_SELECTED_OFFLINE_EVIDENCE_PASS', source_commit=data['proof.json']['source_commit'],
        cases=len(CASES), base_cases=19, semantic_refusal_controls=controls,
        scope='selected observation integrity and consistency; no service execution replay or author authentication')))
