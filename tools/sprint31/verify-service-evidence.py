#!/usr/bin/env python3
"""Verify selected CI observations; this does not replay root service operations."""
import copy
import hashlib
import json
from pathlib import Path
import re
import sys

CASES = {
    'fresh_host_paths_users_units_and_listener_ports',
    'postgres18_container_has_owned_loopback_55449_mapping',
    'application_database_role_is_not_cluster_administrator',
    'credential_source_root0600_not_directly_readable_by_app_user',
    'default_80_443_profile_redirect_follow_accepts_real_explicit_443_Host',
    'downloaded_app_and_delivered_units_are_the_running_processes',
    'systemd_LoadCredential_and_actual_NoNewPrivs_without_URL_in_environment',
    'release_service_publishes_and_numerically_verifies_saved_quality_report',
    'grant_and_viewer_reads_remain_available_while_over_quota',
    'systemctl_restart_changes_app_process_and_preserves_quota_backup_report_and_ledger',
    'viewer_grant_and_write_refusal_survive_application_restart',
    'full_pg_restore_matches_quiescent_source_before_first_target_start',
    'restored_service_retains_overquota_report_and_grants_without_changing_source_database_content',
    'fresh_TCP_authentication_rejects_old_role_password_and_accepts_new_password',
    'stopped_service_loads_rotated_role_credential_without_environment_or_business_data_change',
    'manual_leaf_replacement_and_proxy_restart_serve_new_CA_verified_certificate',
    'proxy_service_restart_keeps_app_and_allows_new_terminal_SSE_connection',
    'fixture_credentials_and_private_keys_not_in_unit_journals',
    'both_owned_units_stop_inactive_with_zero_main_pid_and_successful_exit',
}
FILES = {'proof.json', 'systemd-package-verification.json', 'provenance.json'}
METHOD = 'be4a5a27bb061b0e4fc3a35a365061b4541281d613fd9bde3742572c6defea88'
PROFILES = {
    'deploy/linux/process-intelligence.service': dict(path='/etc/systemd/system/process-intelligence.service', sha256='9c4be964b0a5f572322cdb97ede919caf842b3c2c7d8da580e810d44b0b9d3ae'),
    'deploy/linux/Caddyfile': dict(path='/etc/caddy/Caddyfile', sha256='1bf82b3dac3835c9df1fe8c9fa5e5096cd5f63c79de62d73fa520ae36f021933'),
    'deploy/linux/caddy-process-intelligence.conf': dict(path='/etc/systemd/system/caddy.service.d/process-intelligence.conf', sha256='3133db592a0dc1e1a4ca70fad8338c92813d9ed77e9438c5912a281578375da3'),
}
VENDOR_UNIT = '6c271e030644bd36a0c8956885934f16c928f88202bc126f12cde519ef9693ff'
CADDY_ARCHIVE = '727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b'


def no_duplicates(pairs):
    value = {}
    for key, item in pairs:
        assert key not in value, 'duplicate JSON key'
        value[key] = item
    return value


def load(raw):
    return json.loads(raw.decode('utf-8'), object_pairs_hook=no_duplicates,
        parse_constant=lambda _: (_ for _ in ()).throw(AssertionError('nonfinite JSON')))


def sha(value):
    assert isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value)
    return value


def replay(value):
    assert set(value) == {'status', 'numeric_replay', 'author_signature_verified',
                         'method_sha256', 'input_model_sha256', 'input_variants_sha256'}
    assert value['status'] == 'quality_report_verified'
    assert value['numeric_replay'] is True and value['author_signature_verified'] is False
    assert value['method_sha256'] == METHOD
    sha(value['input_model_sha256'])
    sha(value['input_variants_sha256'])


def profile_identity(row, app):
    assert row['FragmentPath'] == '/etc/systemd/system/' + ('process-intelligence.service' if app else 'caddy.service')
    assert row['DropInPaths'] == ('' if app else '/etc/systemd/system/caddy.service.d/process-intelligence.conf')
    if app:
        assert row['WorkingDirectory'] == '/opt/process-intelligence/current'


def verify_values(data):
    proof, package, origin = (data[name] for name in ['proof.json', 'systemd-package-verification.json', 'provenance.json'])
    assert proof['status'] == 'S31_SYSTEMD_RELEASE_PROFILE_PASS'
    assert package['status'] == 'S30_DOWNLOADED_LINUX_PACKAGE_PASS'
    source = proof['source_commit']
    assert re.fullmatch('[0-9a-f]{40}', source)
    assert package['source_commit'] == package['build_environment']['source_commit'] == origin['source_commit'] == source
    assert package['build_environment']['system'] == 'Linux' and package['build_environment']['machine'] == 'x86_64'
    assert package['archive_sha256'] == sha(proof['package_archive_sha256'])
    assert proof['global_CA_store_modified'] is False
    assert proof['installed_profile_files'] == PROFILES
    assert proof['vendor_unit_sha256'] == VENDOR_UNIT and proof['caddy_archive_sha256'] == CADDY_ARCHIVE
    assert proof['active_database'] == 'pi_s31_restored_ci'
    assert len(proof['cases']) == len(CASES)
    assert {row['case'] for row in proof['cases']} == CASES
    assert all(set(row) == {'case', 'outcome'} and row['outcome'] == 'pass' for row in proof['cases'])
    for name in ['package_manifest_sha256', 'package_app_sha256', 'vendor_unit_sha256', 'caddy_archive_sha256',
                 'private_dump_sha256', 'prestart_source_and_restore_snapshot_sha256', 'leaf_before_der_sha256',
                 'leaf_after_der_sha256', 'report_sha256', 'project_backup_sha256', 'accounting_sha256']:
        sha(proof[name])
    assert proof['leaf_before_der_sha256'] != proof['leaf_after_der_sha256']
    identities = [proof[name] for name in ['app_before', 'app_after_normal_restart', 'app_after_restore', 'app_after_credential_rotation']]
    for row in identities:
        profile_identity(row, True)
        assert row['ActiveState'] == 'active' and int(row['MainPID']) > 1
        assert row['User'] == row['Group'] == 'process-intelligence'
        assert row['NoNewPrivileges'] == 'yes' and row['ProtectSystem'] == 'strict'
        assert row['NRestarts'] == row['ExecMainStatus'] == '0' and row['Result'] == 'success'
        assert row['executable_sha256'] == proof['package_app_sha256']
    assert len({row['MainPID'] for row in identities}) == 4
    times = [int(row['ExecMainStartTimestampMonotonic']) for row in identities]
    assert all(a < b for a, b in zip(times, times[1:]))
    assert proof['app_after'] == identities[-1]
    before, after = proof['proxy_before'], proof['proxy_after']
    assert before['MainPID'] != after['MainPID']
    assert int(before['ExecMainStartTimestampMonotonic']) < int(after['ExecMainStartTimestampMonotonic'])
    for row in [before, after]:
        profile_identity(row, False)
        assert row['ActiveState'] == 'active' and int(row['MainPID']) > 1
        assert row['User'] == row['Group'] == 'caddy'
        assert row['NRestarts'] == row['ExecMainStatus'] == '0' and row['Result'] == 'success'
        assert row['executable_sha256'] == before['executable_sha256']
    for name in ['app_stopped', 'proxy_stopped']:
        row = proof[name]
        profile_identity(row, name == 'app_stopped')
        assert row['ActiveState'] == 'inactive' and row['MainPID'] == row['NRestarts'] == row['ExecMainStatus'] == '0'
        assert row['Result'] == 'success'
    assert proof['quota']['enabled'] is True
    assert type(proof['quota']['payload_allowance']) is int and proof['quota']['payload_allowance'] == 0
    assert type(proof['quota']['payload_used']) is int and proof['quota']['payload_used'] > 0
    assert proof['quota']['metric'] == 'structural_bytes_v1' and proof['quota']['header_reserve'] == 268369920
    replay(proof['numeric_replay'])
    assert len(package['reports']) == 2
    for row in package['reports']:
        sha(row['report_sha256'])
        replay(row['verification'])
    commands = proof['commands']
    contract = load(Path(__file__).with_name('service-command-contract.json').read_bytes())
    assert type(contract['schema_version']) is int and contract['schema_version'] == 1
    assert len(commands) == len(contract['commands'])
    for row, expected in zip(commands, contract['commands']):
        assert row['label'] == expected['label'] and row['program'] == expected['program']
        assert type(row['native_exit']) is int and row['native_exit'] in expected['allowed_exits']
    old = [row for row in commands if row['label'] == 'old-role-password-refused']
    new = [row for row in commands if row['label'] == 'new-role-password-accepted']
    assert len(old) == len(new) == 1 and old[0]['native_exit'] == 2 and new[0]['native_exit'] == 0
    for row in commands:
        assert set(row) == {'label', 'program', 'native_exit', 'stdout_sha256', 'stderr_sha256'}
        sha(row['stdout_sha256'])
        sha(row['stderr_sha256'])
    events = [row for row in proof['requests'] if row['path'].endswith('/events')]
    assert events and all(row['status'] == 200 and row['content_type'].startswith('text/event-stream') for row in events)
    stable_requests = []
    report_paths, project_paths = set(), set()
    for row in proof['requests']:
        assert set(row) == {'method', 'path', 'status', 'content_type', 'bytes', 'sha256'}
        assert row['method'] in ('GET', 'POST') and type(row['status']) is int and 100 <= row['status'] <= 599
        assert type(row['bytes']) is int and 0 <= row['bytes'] <= 4 * 1024 * 1024
        assert isinstance(row['content_type'], str) and len(row['content_type']) <= 512
        assert row['path'].startswith('/') and '\n' not in row['path'] and '\r' not in row['path']
        sha(row['sha256'])
        if row['path'] == '/health':
            assert row['method'] == 'GET' and row['status'] in (200, 502, 503)
            continue
        if re.fullmatch('/quality/jobs/job-[0-9]+', row['path']):
            assert row['method'] == 'GET' and row['status'] == 200
            continue
        if row['path'].endswith('/report'):
            report_paths.add(row['path'])
            assert row['sha256'] == proof['report_sha256']
        if row['path'].startswith('/projects/'):
            project_paths.add(row['path'].split('/')[2])
        stable_requests.append(row)
    assert len(report_paths) == len(project_paths) == 1
    assert len(stable_requests) == len(contract['requests'])
    for row, expected in zip(stable_requests, contract['requests']):
        assert row['method'] == expected['method'] and row['status'] == expected['status']
        assert re.fullmatch(expected['path_pattern'], row['path'])
    assert type(origin['run_id']) is int and type(origin['job_id']) is int and type(origin['artifact_id']) is int
    sha(origin['artifact_zip_sha256'])
    assert origin['scope'] == 'selected observations downloaded from GitHub Actions; integrity checks do not replay service operations or authenticate authorship'


def verify(root):
    assert not root.is_symlink()
    assert {p.name for p in root.iterdir()} == FILES | {'manifest.json'}
    manifest = load((root / 'manifest.json').read_bytes())
    assert set(manifest) == {'schema_version', 'files'} and type(manifest['schema_version']) is int and manifest['schema_version'] == 1
    assert len(manifest['files']) == len(FILES)
    seen, data = set(), {}
    for row in manifest['files']:
        assert set(row) == {'path', 'bytes', 'sha256'} and row['path'] in FILES and row['path'] not in seen
        seen.add(row['path'])
        path = root / row['path']
        assert path.is_file() and not path.is_symlink()
        raw = path.read_bytes()
        assert type(row['bytes']) is int and len(raw) == row['bytes']
        assert hashlib.sha256(raw).hexdigest() == sha(row['sha256'])
        data[row['path']] = load(raw)
    assert seen == FILES
    verify_values(data)
    return data


if __name__ == '__main__':
    data = verify(Path(sys.argv[1]))
    controls = 0
    if '--self-test' in sys.argv[2:]:
        for field, value in [('cases', []), ('app_after', data['proof.json']['app_before']),
                             ('leaf_after_der_sha256', data['proof.json']['leaf_before_der_sha256'])]:
            changed = copy.deepcopy(data)
            changed['proof.json'][field] = value
            try:
                verify_values(changed)
            except AssertionError:
                controls += 1
            else:
                raise AssertionError('semantic alteration accepted: ' + field)
        changed = copy.deepcopy(data)
        changed['proof.json']['numeric_replay']['author_signature_verified'] = True
        try:
            verify_values(changed)
        except AssertionError:
            controls += 1
        else:
            raise AssertionError('unsupported signature claim accepted')
        for change in ['missing-command', 'failed-command', 'boolean-exit', 'foreign-unit', 'missing-profile', 'missing-request']:
            changed = copy.deepcopy(data)
            proof = changed['proof.json']
            if change == 'missing-command':
                proof['commands'].pop()
            elif change == 'failed-command':
                next(row for row in proof['commands'] if row['label'] == 'restart-app')['native_exit'] = 99
            elif change == 'boolean-exit':
                proof['commands'][0]['native_exit'] = False
            elif change == 'foreign-unit':
                proof['app_after_restore']['FragmentPath'] = '/etc/systemd/system/foreign.service'
            elif change == 'missing-profile':
                proof['installed_profile_files'] = {}
            else:
                proof['requests'] = [row for row in proof['requests'] if row['path'] != '/users']
            try:
                verify_values(changed)
            except AssertionError:
                controls += 1
            else:
                raise AssertionError('semantic alteration accepted: ' + change)
    print(json.dumps(dict(status='S31_SELECTED_SERVICE_EVIDENCE_PASS', source_commit=data['proof.json']['source_commit'],
        cases=len(CASES), semantic_refusal_controls=controls,
        scope='selected observation integrity and consistency; no root execution replay or author signature verification')))
