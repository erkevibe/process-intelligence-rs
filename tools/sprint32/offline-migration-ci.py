#!/usr/bin/env python3
"""CI-only v6 offline CLI rehearsal; inherits the fresh-VM S31 ownership guards."""
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


HERE = Path(__file__).resolve()
service = module('s31_fixture', HERE.parents[1] / 'sprint31/systemd-profile-ci.py')
evidence = module('s31_evidence', HERE.parents[1] / 'sprint31/verify-service-evidence.py')
UNITS = ('pi-s32-migrate-repeat.service', 'pi-s32-migrate-refuse.service')
SCHEMA_REFUSAL = 'Схема или сохранённые данные не поддерживаются. Исходные записи не изменены; проверьте состояние миграции.'


class OfflineRehearsal:
    def __init__(self, fixture):
        assert os.environ.get('S32_OWNED_OFFLINE_FIXTURE') == 'yes'
        self.f = fixture
        assert service.digest(HERE.read_bytes()) == fixture.files['tools/sprint32/offline-migration-ci.py']['sha256']
        assert service.digest(Path(evidence.__file__).read_bytes()) == fixture.files['tools/sprint31/verify-service-evidence.py']['sha256']
        self.output = fixture.workspace / '.local/sprint32/offline-migration'
        assert not self.output.exists() and self.output.parent.resolve().is_relative_to(fixture.workspace)
        self.output.mkdir(parents=True, mode=0o700)
        self.commands, self.requests, self.cases = [], [], []
        self.transient_diagnostics = []

    @contextmanager
    def observations(self):
        f = self.f
        original = f.output, f.commands, f.requests, f.client if hasattr(f, 'client') else None
        f.output, f.commands, f.requests = self.output, self.commands, self.requests
        if original[3] is not None:
            f.client = service.Client(self.output / 'ca.pem', self.requests)
        try:
            yield
        finally:
            f.output, f.commands, f.requests = original[:3]
            if original[3] is not None:
                f.client = original[3]

    def check(self, name, condition):
        assert condition, name
        self.cases.append(dict(case=name, outcome='pass'))

    def properties(self, unit, names):
        assert unit in UNITS
        raw = self.f.call('s32-transient-properties', ['systemctl', 'show', unit] + ['--property=' + name for name in names]).stdout.decode()
        return dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)

    def preflight(self):
        with self.observations():
            for unit in UNITS:
                raw = self.f.call('s32-transient-absent', ['systemctl', 'show', unit, '--property=LoadState', '--value'], allowed=(0, 1)).stdout
                assert raw.strip() == b'not-found'
                path = Path('/run/systemd/transient', unit)
                assert not path.exists() and not path.is_symlink() and path.resolve() == path
        self.check('fixed_transient_unit_names_and_paths_are_absent', True)

    def stopped(self):
        self.f.identity(service.APP, stopped=True)
        self.f.identity(service.PROXY, stopped=True)

    def sql(self, label, statement):
        assert self.f.active_database == 'pi_s31_restored_ci'
        return self.f.call(label, ['docker', 'exec', '-i', self.f.container, 'psql', '-X', '-qAt',
            '-U', 'pi_s31_admin', '-d', 'pi_s31_restored_ci', '-v', 'ON_ERROR_STOP=1'], statement.encode()).stdout.strip()

    def retire(self, unit):
        f = self.f
        assert unit in UNITS and unit in f.installed
        f.call('s32-stop-owned-transient', ['sudo', 'systemctl', 'stop', unit], timeout=20)
        state = self.properties(unit, ['ActiveState', 'MainPID', 'LoadState'])
        if state['ActiveState'] == 'failed':
            f.call('s32-reset-owned-failure', ['sudo', 'systemctl', 'reset-failed', unit])
            state = self.properties(unit, ['ActiveState', 'MainPID', 'LoadState'])
        assert state['ActiveState'] == 'inactive' and state['MainPID'] == '0'
        assert state['LoadState'] in ('loaded', 'not-found')
        f.installed.remove(unit)
        return state

    def credential_binding(self, unit):
        assert unit in UNITS
        encoded = ''.join(char if char.isascii() and char.isalnum() else '_' + format(ord(char), '02x') for char in unit)
        path = '/org/freedesktop/systemd1/unit/' + encoded
        owner = evidence.load(self.f.call('s32-unit-object', ['busctl', '--json=short', 'call',
            'org.freedesktop.systemd1', '/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager', 'GetUnit', 's', unit]).stdout)
        assert owner == dict(type='o', data=[path])
        binding = evidence.load(self.f.call('s32-credential-binding', ['busctl', '--json=short', 'get-property',
            'org.freedesktop.systemd1', path, 'org.freedesktop.systemd1.Service', 'LoadCredential']).stdout)
        # LoadCredential is a(ss), not a scalar. Read the actual D-Bus value;
        # systemctl's human-readable formatter need not represent this type.
        assert binding == dict(type='a(ss)', data=[['database-url', '/etc/process-intelligence/database-url']])
        return dict(unit=unit, object_path=path, property=binding)

    def cli(self, unit, expected):
        f = self.f
        assert unit in UNITS and expected in (0, 1)
        self.stopped()
        assert self.properties(unit, ['LoadState'])['LoadState'] == 'not-found'
        args = ['sudo', 'systemd-run', '--quiet', '--unit=' + unit, '--service-type=oneshot', '--remain-after-exit']
        settings = dict(User='process-intelligence', Group='process-intelligence',
            WorkingDirectory='/opt/process-intelligence/current', Restart='no',
            LoadCredential='database-url:/etc/process-intelligence/database-url',
            Environment='PI_DATABASE_URL_FILE=/run/credentials/' + unit + '/database-url', UnsetEnvironment='PI_DATABASE_URL PI_EPHEMERAL',
            NoNewPrivileges='yes', ProtectSystem='strict', PrivateTmp='yes', UMask='0077',
            TimeoutStartSec='20s', TimeoutStopSec='10s')
        args += ['--property=' + key + '=' + value for key, value in settings.items()]
        args += ['/opt/process-intelligence/current/process-intelligence-rs', '--migrate-storage']
        # Track before launch so a timeout/failed start still reaches owned-only
        # cleanup. Failure to prove a stop keeps the S31 firewall in place.
        f.installed.append(unit)
        completed = f.call('s32-offline-cli-' + str(expected), args, timeout=30, allowed=(expected,))
        names = ['LoadState', 'ActiveState', 'SubState', 'MainPID', 'ExecMainPID', 'ExecMainCode',
                 'ExecMainStatus', 'Result', 'Transient', 'Type', 'RemainAfterExit', 'Restart',
                 'User', 'Group', 'WorkingDirectory', 'LoadCredential', 'Environment', 'UnsetEnvironment',
                 'NoNewPrivileges', 'ProtectSystem', 'SuccessExitStatus', 'FragmentPath', 'ExecStart']
        props = self.properties(unit, names)
        safe_names = ['LoadState', 'ActiveState', 'SubState', 'MainPID', 'ExecMainPID', 'ExecMainCode',
            'ExecMainStatus', 'Result', 'Transient', 'Type', 'RemainAfterExit', 'Restart', 'User', 'Group',
            'WorkingDirectory', 'NoNewPrivileges', 'ProtectSystem', 'SuccessExitStatus', 'FragmentPath', 'LoadCredential']
        safe = {}
        secrets = [f.database_url, f.owner_password, f.viewer_password] + f.password_history
        for name in safe_names:
            value = props.get(name, '<missing>')
            safe[name] = value if len(value) <= 512 and not any(secret in value for secret in secrets) else '<redacted>'
        self.transient_diagnostics.append(dict(unit=unit, wrapper_exit=completed.returncode, safe_properties=safe,
            environment_matches=props.get('Environment') == settings['Environment'],
            credential_scalar_matches=props.get('LoadCredential') == settings['LoadCredential'],
            expected_exec_argv='argv[]=/opt/process-intelligence/current/process-intelligence-rs --migrate-storage ;' in props.get('ExecStart', '')))
        binding = self.credential_binding(unit)
        self.transient_diagnostics[-1]['typed_credential_binding_verified'] = True
        assert props['LoadState'] == 'loaded' and props['Transient'] == props['RemainAfterExit'] == 'yes'
        assert props['Type'] == 'oneshot' and props['Restart'] == 'no' and props['SuccessExitStatus'] == ''
        assert props['FragmentPath'] == '/run/systemd/transient/' + unit
        assert props['User'] == props['Group'] == 'process-intelligence'
        assert props['WorkingDirectory'] == '/opt/process-intelligence/current'
        assert props['Environment'] == settings['Environment']
        assert set(props['UnsetEnvironment'].split()) == {'PI_DATABASE_URL', 'PI_EPHEMERAL'}
        assert props['NoNewPrivileges'] == 'yes' and props['ProtectSystem'] == 'strict'
        assert props['MainPID'] == '0' and int(props['ExecMainPID']) > 1 and props['ExecMainCode'] == '1'
        assert props['ExecMainStatus'] == str(expected)
        assert props['Result'] == ('success' if expected == 0 else 'exit-code')
        assert props['ActiveState'] == ('active' if expected == 0 else 'failed')
        assert props['SubState'] == ('exited' if expected == 0 else 'failed')
        assert 'argv[]=/opt/process-intelligence/current/process-intelligence-rs --migrate-storage ;' in props['ExecStart']
        assert 'ignore_errors=no' in props['ExecStart']
        reason = None
        diagnostic_source = None
        if expected == 1:
            raw = f.call('s32-private-schema-refusal-journal', ['sudo', 'journalctl', '-u', unit, '--no-pager', '-o', 'json', '-n', '50']).stdout
            entries = [evidence.load(line) for line in raw.splitlines()]
            assert any(isinstance(row.get('MESSAGE'), str) and SCHEMA_REFUSAL in row['MESSAGE']
                and str(row.get('_PID', '')) == props['ExecMainPID'] and row.get('_SYSTEMD_UNIT') == unit
                for row in entries), 'expected schema refusal diagnostic from actual CLI PID/unit not observed'
            reason = 'schema_unsupported'
            diagnostic_source = dict(unit=unit, pid=props['ExecMainPID'], matched_message_sha256=service.digest(SCHEMA_REFUSAL.encode()))
        return dict(wrapper_native_exit=completed.returncode, configured_unit_properties=props,
                    credential_binding=binding, normalized_refusal_reason=reason, refusal_journal_source=diagnostic_source,
                    retired=self.retire(unit), process_proc_identity_observed=False)

    def exercise(self):
        f = self.f
        shutil.copyfile(f.output / 'ca.pem', self.output / 'ca.pem')
        with self.observations():
            self.stopped()
            before = f.database_snapshot('pi_s31_restored_ci')
            self.baseline_sha = service.digest(before)
            self.repeat = self.cli(UNITS[0], 0)
            assert f.database_snapshot('pi_s31_restored_ci') == before
            self.check('offline_v6_repeat_through_LoadCredential_keeps_full_database_snapshot', True)
            original = self.sql('s32-read-owned-checksum', 'SELECT checksum FROM public.pi_schema_migrations WHERE version=6;').decode()
            assert re.fullmatch('[0-9a-f]{64}', original) and original != '0' * 64
            bad = '0' * 64
            changed = self.sql('s32-corrupt-only-owned-v6-checksum', "UPDATE public.pi_schema_migrations SET checksum='" + bad + "' WHERE version=6 AND checksum='" + original + "' RETURNING checksum;")
            assert changed.decode() == bad
            corrupted = f.database_snapshot('pi_s31_restored_ci')
            assert corrupted != before
            self.corrupted_sha = service.digest(corrupted)
            self.refused = self.cli(UNITS[1], 1)
            assert f.database_snapshot('pi_s31_restored_ci') == corrupted
            self.check('offline_CLI_checksum_refusal_exit1_keeps_corrupted_snapshot_unchanged', True)
            repaired = self.sql('s32-repair-only-original-fixture-checksum', "UPDATE public.pi_schema_migrations SET checksum='" + original + "' WHERE version=6 AND checksum='" + bad + "' RETURNING checksum;")
            assert repaired.decode() == original and f.database_snapshot('pi_s31_restored_ci') == before
            self.check('explicit_owned_fixture_repair_restores_exact_pretest_snapshot', True)
            f.call('s32-start-app', ['sudo', 'systemctl', 'start', service.APP], timeout=60)
            f.call('s32-start-proxy', ['sudo', 'systemctl', 'start', service.PROXY], timeout=15)
            f.health()
            self.app_after = f.identity(service.APP)
            self.proxy_after = f.identity(service.PROXY)
            assert self.app_after['MainPID'] != f.after_app['MainPID']
            assert int(self.app_after['ExecMainStartTimestampMonotonic']) > int(f.after_app['ExecMainStartTimestampMonotonic'])
            assert self.proxy_after['MainPID'] != f.after_proxy['MainPID']
            assert int(self.proxy_after['ExecMainStartTimestampMonotonic']) > int(f.after_proxy['ExecMainStartTimestampMonotonic'])
            cookies = f.login_and_verify_retained()
            self.check('new_service_process_preserves_report_quota_ledger_and_viewer_grant_after_offline_CLI', True)
            journal = f.call('s32-private-migration-journals', ['sudo', 'journalctl', '-u', UNITS[0], '-u', UNITS[1], '--no-pager', '-o', 'json', '-n', '150']).stdout
            assert all(value.encode() not in journal for value in [f.database_url, f.owner_password, f.viewer_password] + f.password_history + list(cookies))
            assert b'BEGIN PRIVATE KEY' not in journal
            self.check('offline_unit_journals_do_not_contain_fixture_secrets', True)
            f.call('s32-stop-proxy', ['sudo', 'systemctl', 'stop', service.PROXY], timeout=15)
            f.call('s32-stop-app', ['sudo', 'systemctl', 'stop', service.APP], timeout=60)
            self.app_stopped, self.proxy_stopped = f.identity(service.APP, stopped=True), f.identity(service.PROXY, stopped=True)
            self.check('all_owned_services_and_transient_jobs_are_stopped_before_firewall_cleanup', all(unit not in f.installed for unit in UNITS))

    def proof(self):
        return dict(status='S32_OFFLINE_CREDENTIAL_MIGRATION_PASS', source_commit=self.f.source,
            cases=self.cases, commands=self.commands, requests=self.requests,
            baseline_snapshot_sha256=self.baseline_sha, corrupted_snapshot_sha256=self.corrupted_sha,
            repeat=self.repeat, refusal=self.refused, app_after=self.app_after, proxy_after=self.proxy_after,
            app_stopped=self.app_stopped, proxy_stopped=self.proxy_stopped,
            scope='fresh owned Ubuntu24.04 VM; v6 idempotent repeat and deliberate synthetic checksum refusal/repair only, not v5 upgrade or production migration; short CLI configured unit properties observed, no live /proc UID/NoNewPrivs claim; S31 firewall remains until all owned units stop; failed fixtures are discarded, never repaired automatically')


if __name__ == '__main__':
    os.umask(0o077)
    f = service.Fixture()
    rehearsal = OfflineRehearsal(f)
    failure = None
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        rehearsal.preflight()
        f.preflight()
        f.install()
        f.exercise()
        rehearsal.exercise()
    except BaseException as error:
        failure = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            f.cleanup()
        except BaseException as error:
            failure = (failure or '') + '; cleanup: ' + type(error).__name__ + ': ' + str(error)
    if failure:
        (rehearsal.output / 'failure.json').write_text(json.dumps(dict(status='S32_OFFLINE_REHEARSAL_FAILED', failure=failure,
            cases=rehearsal.cases, commands=rehearsal.commands, transient_diagnostics=rehearsal.transient_diagnostics), indent=2) + '\n')
        raise SystemExit('S32_OFFLINE_REHEARSAL_FAILED: ' + failure)
    base = f.proof()
    package = json.loads((f.workspace / 'systemd-package-verification.json').read_text())
    evidence.verify_core(base, package)
    (rehearsal.output / 'base-profile-proof.json').write_text(json.dumps(base, indent=2) + '\n')
    result = rehearsal.proof()
    (rehearsal.output / 'proof.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(status=result['status'], source_commit=f.source, cases=len(rehearsal.cases),
        base_profile_consistency='S31_LIVE_SERVICE_OBSERVATIONS_PASS')))
