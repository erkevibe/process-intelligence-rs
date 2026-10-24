#!/usr/bin/env python3
"""Fresh-VM, synthetic v5 reconstruction and non-superuser file-credential upgrade."""
import copy
import json
import os
from pathlib import Path
import shutil
import signal

HERE = Path(__file__).resolve()
import importlib.util


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


offline = module('s32_offline', HERE.parents[1] / 'sprint32/offline-migration-ci.py')
checker = module('s32_checker', HERE.parents[1] / 'sprint32/verify-offline-evidence.py')
audit = module('s30_accounting', HERE.parents[1] / 'sprint30/audit-quota.py')
DB = 'pi_s33_v5_ci'
QUOTA = "'quota',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY project_id),'[]') FROM public.pi_project_quota t),"
CATALOGS = ('tables', 'columns', 'constraints', 'indexes', 'triggers')


class Upgrade(offline.OfflineRehearsal):
    def __init__(self, fixture, previous):
        assert os.environ.get('S33_OWNED_V5_FIXTURE') == 'yes'
        self.f = fixture
        self.previous = previous
        assert offline.service.digest(HERE.read_bytes()) == fixture.files['tools/sprint33/v5-cli-upgrade-ci.py']['sha256']
        self.output = fixture.workspace / '.local/sprint33/v5-upgrade'
        assert not self.output.exists() and self.output.parent.resolve().is_relative_to(fixture.workspace)
        self.output.mkdir(parents=True, mode=0o700)
        self.commands, self.requests, self.cases, self.transient_diagnostics = [], [], [], []

    def query(self, label, sql, database=DB):
        assert database in ('postgres', 'pi_s31_restored_ci', DB)
        return self.f.call(label, ['docker', 'exec', '-i', self.f.container, 'psql', '-X', '-qAt',
            '-U', 'pi_s31_admin', '-d', database, '-v', 'ON_ERROR_STOP=1'], sql.encode()).stdout

    def preflight(self):
        with self.observations():
            assert self.query('s33-database-absent', "SELECT count(*) FROM pg_database WHERE datname='pi_s33_v5_ci';", 'postgres').strip() == b'0'
        self.check('third_owned_database_absent_before_changes', True)

    def snapshot(self, v5=False):
        sql = (self.f.package / 'tools/sprint30/storage-snapshot.sql').read_text()
        assert sql.count(QUOTA) == 1
        if v5:
            sql = sql.replace(QUOTA, "'quota','[]'::jsonb,")
        raw = self.query('s33-v5-snapshot' if v5 else 's33-v6-snapshot', sql)
        return raw, offline.evidence.load(raw)

    @staticmethod
    def without_v6(value):
        result = copy.deepcopy(value)
        result['quota'] = []
        result['ledger'] = [row for row in result['ledger'] if row['version'] <= 5]
        for name in CATALOGS:
            result[name] = [row for row in result[name] if row[0] != 'pi_project_quota']
        return result

    def recount(self):
        records = offline.evidence.load(self.query('s33-private-records-for-recount', "SELECT coalesce(jsonb_agg(jsonb_build_object('project',project_id,'kind',kind,'id',resource_id,'version',version,'document',document) ORDER BY project_id,kind,resource_id),'[]') FROM public.pi_records;"))
        quotas = offline.evidence.load(self.query('s33-private-quota-counters', 'SELECT jsonb_agg(to_jsonb(q) ORDER BY project_id) FROM public.pi_project_quota q;'))
        projects = offline.evidence.load(self.query('s33-project-ids', 'SELECT jsonb_agg(project_id ORDER BY project_id) FROM public.pi_projects;'))
        assert [row['project_id'] for row in quotas] == projects
        summaries, snapshots = [], []
        for quota in quotas:
            ledger, total, count = {}, 0, 0
            for row in records:
                if row['project'] != quota['project_id']:
                    continue
                assert row['kind'] in audit.KINDS and type(row['version']) is int and row['version'] > 0
                measured = 32 + len(row['kind'].encode()) + len(row['id'].encode()) + audit.cost(row['document'])
                group = ledger.setdefault(row['kind'], {})
                assert row['id'] not in group
                group[row['id']] = dict(version=row['version'], cost=measured)
                total += measured
                count += 1
            assert quota['metric_version'] == 1 and quota['payload_used'] == total and quota['record_costs'] == ledger
            summaries.append(dict(project_id=quota['project_id'], records=count, payload_used=total))
            snapshots.append(dict(name=quota['project_id'], payload_used=total,
                records=[{key: row[key] for key in ('kind', 'id', 'document')} for row in records if row['project'] == quota['project_id']]))
        self.accounting_input = dict(schema_version=1, metric='structural_bytes_v1', header_reserve=268369920, snapshots=snapshots)
        self.accounting_verification = audit.verify(self.accounting_input)
        return summaries

    def exercise(self):
        f = self.f
        shutil.copyfile(f.output / 'ca.pem', self.output / 'ca.pem')
        original_db, original_url = f.active_database, f.database_url
        assert original_db == 'pi_s31_restored_ci'
        with self.observations():
            self.stopped()
            source_raw = f.database_snapshot('pi_s31_restored_ci')
            source = offline.evidence.load(source_raw)
            self.source_sha = offline.service.digest(source_raw)
            dump = f.call('s33-private-clone-dump', ['docker', 'exec', f.container, 'pg_dump', '-U', 'pi_s31_admin', '-d', original_db, '-Fc']).stdout
            self.query('s33-create-owned-clone', 'CREATE DATABASE pi_s33_v5_ci OWNER pi_s31_app;', 'postgres')
            f.call('s33-restore-owned-clone', ['docker', 'exec', '-i', f.container, 'pg_restore', '-U', 'pi_s31_admin', '-d', DB,
                '--single-transaction', '--exit-on-error', '--no-owner', '--no-privileges', '--role=pi_s31_app'], dump)
            assert self.snapshot()[0] == source_raw
            self.check('fresh_clone_matches_quiescent_source_before_fixture_reconstruction', True)
            self.role = offline.evidence.load(self.query('s33-ownership-and-role', "SELECT jsonb_build_object('database_owner',(SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()),'superuser',(SELECT rolsuper FROM pg_roles WHERE rolname='pi_s31_app'),'createdb',(SELECT rolcreatedb FROM pg_roles WHERE rolname='pi_s31_app'),'createrole',(SELECT rolcreaterole FROM pg_roles WHERE rolname='pi_s31_app'),'foreign_public_owners',(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','S') AND pg_get_userbyid(c.relowner)<>'pi_s31_app'));"))
            assert self.role == dict(database_owner='pi_s31_app', superuser=False, createdb=False, createrole=False, foreign_public_owners=0)
            self.check('non_superuser_database_role_owns_all_restored_tables_and_sequence', True)
            expected = self.without_v6(source)
            expected['projects'] = offline.evidence.load(self.query('s33-expected-header-policy-removal', "SELECT jsonb_agg(jsonb_build_array(project_id,version,encode(sha256(convert_to((document-'quota_policy')::text,'UTF8')),'hex')) ORDER BY project_id) FROM public.pi_projects;", original_db))
            self.query('s33-construct-only-synthetic-v5', "BEGIN; DROP TABLE public.pi_project_quota; DELETE FROM public.pi_schema_migrations WHERE version=6; UPDATE public.pi_projects SET document=document-'quota_policy' WHERE document ? 'quota_policy'; COMMIT;")
            v5_raw, v5 = self.snapshot(v5=True)
            assert v5 == expected and [row['version'] for row in v5['ledger']] == [1, 2, 3, 4, 5]
            absent = offline.evidence.load(self.query('s33-v5-barrier-and-policies', "SELECT jsonb_build_object('quota_absent',to_regclass('public.pi_project_quota') IS NULL,'policy_headers',(SELECT count(*) FROM public.pi_projects WHERE document ? 'quota_policy'));"))
            assert absent == dict(quota_absent=True, policy_headers=0)
            self.v5_sha = offline.service.digest(v5_raw)
            self.check('synthetic_v5_exact_ledger_schema_and_all_data_match_only_declared_differences', True)
            f.active_database = DB
            f.database_url = 'postgresql://pi_s31_app:' + f.password + '@127.0.0.1:55449/' + DB + '?connect_timeout=5'
            f.replace_credential('restore')
            self.upgrade = self.cli(offline.UNITS[0], 0)
            v6_raw, v6 = self.snapshot()
            assert self.without_v6(v6) == v5
            assert [row['version'] for row in v6['ledger']] == [1, 2, 3, 4, 5, 6]
            new_ledger = v6['ledger'][-1]
            assert {key: new_ledger[key] for key in ('version', 'name', 'checksum')} == {key: source['ledger'][-1][key] for key in ('version', 'name', 'checksum')}
            assert isinstance(new_ledger['applied_at'], str) and new_ledger['applied_at']
            assert new_ledger['applied_at'] != source['ledger'][-1]['applied_at']
            for name in CATALOGS:
                assert [row for row in v6[name] if row[0] == 'pi_project_quota'] == [row for row in source[name] if row[0] == 'pi_project_quota']
            assert self.query('s33-new-quota-table-owner', "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid='public.pi_project_quota'::regclass;").strip() == b'pi_s31_app'
            self.v6_sha = offline.service.digest(v6_raw)
            self.check('file_credential_CLI_really_creates_v6_DDL_under_non_superuser_and_preserves_v5_projection', True)
            self.accounting = self.recount()
            self.check('independent_recount_matches_every_project_counter_and_record_version_cost', True)
            self.repeat = self.cli(offline.UNITS[0], 0)
            assert self.snapshot()[0] == v6_raw
            self.check('second_offline_CLI_is_exact_v6_noop_after_real_upgrade', True)
            f.call('s33-start-app', ['sudo', 'systemctl', 'start', offline.service.APP], timeout=60)
            f.call('s33-start-proxy', ['sudo', 'systemctl', 'start', offline.service.PROXY], timeout=15)
            f.health()
            self.app_after, self.proxy_after = f.identity(offline.service.APP), f.identity(offline.service.PROXY)
            for current, previous in [(self.app_after, self.previous.app_after), (self.proxy_after, self.previous.proxy_after)]:
                assert current['MainPID'] != previous['MainPID']
                assert int(current['ExecMainStartTimestampMonotonic']) > int(previous['ExecMainStartTimestampMonotonic'])
            self.client = offline.service.Client(self.output / 'ca.pem', self.requests)
            assert self.client.request('POST', '/login', dict(username='s31_owner', password=f.owner_password))[0] == 303
            self.quota = self.client.get('/quota/status')
            assert self.quota['enabled'] is False and self.quota['metric'] == 'structural_bytes_v1'
            assert self.quota['payload_used'] == next(row['payload_used'] for row in self.accounting if row['project_id'] == f.project)
            assert self.client.request('GET', f.report_path) == (200, f.report)
            viewer = offline.service.Client(self.output / 'ca.pem', self.requests)
            assert viewer.request('POST', '/login', dict(username='s31_viewer', password=f.viewer_password))[0] == 303
            assert viewer.request('POST', '/projects/' + f.project + '/open', {})[0] == 303
            assert viewer.request('GET', f.report_path) == (200, f.report)
            assert viewer.request('POST', '/quota', dict(revision=0, mode='disabled', payload_allowance=0))[0] == 403
            assert f.database_snapshot('pi_s31_restored_ci') == source_raw
            self.check('new_service_reads_migrated_report_and_grants_with_default_off_quota_and_unchanged_source', True)
            journal = f.call('s33-private-service-and-cli-journals', ['sudo', 'journalctl', '-u', offline.UNITS[0],
                '-u', offline.service.APP, '-u', offline.service.PROXY, '--no-pager', '-o', 'json', '-n', '150']).stdout
            known = [f.database_url, original_url, f.owner_password, f.viewer_password] + f.password_history
            known += [cookie.value for client in [self.client, viewer] for cookie in client.jar]
            assert all(value.encode() not in journal for value in known) and b'BEGIN PRIVATE KEY' not in journal
            self.check('known_fixture_secrets_not_in_service_or_migration_journals', True)
            f.call('s33-stop-proxy', ['sudo', 'systemctl', 'stop', offline.service.PROXY], timeout=15)
            f.call('s33-stop-app', ['sudo', 'systemctl', 'stop', offline.service.APP], timeout=60)
            self.app_stopped, self.proxy_stopped = f.identity(offline.service.APP, stopped=True), f.identity(offline.service.PROXY, stopped=True)
            f.active_database, f.database_url = original_db, original_url
            f.replace_credential('restore')
            actual = f.call('s33-private-restored-credential-sha', ['sudo', 'sha256sum', '/etc/process-intelligence/database-url']).stdout.decode().split()[0]
            assert actual == offline.service.digest((original_url + '\n').encode())
            assert f.database_snapshot('pi_s31_restored_ci') == source_raw
            self.check('all_services_stopped_and_original_credential_target_restored_without_source_writes', True)

    def proof(self):
        return dict(status='S33_NON_SUPERUSER_V5_CLI_UPGRADE_PASS', source_commit=self.f.source, cases=self.cases,
            commands=self.commands, requests=self.requests, role=self.role, upgrade=self.upgrade, repeat=self.repeat,
            source_snapshot_sha256=self.source_sha, v5_snapshot_sha256=self.v5_sha, v6_snapshot_sha256=self.v6_sha,
            independent_accounting=self.accounting, quota=self.quota, app_after=self.app_after, proxy_after=self.proxy_after,
            app_stopped=self.app_stopped, proxy_stopped=self.proxy_stopped, report_sha256=offline.service.digest(self.f.report),
            independent_accounting_verification=self.accounting_verification,
            scope='fresh owned Ubuntu24.04 VM, third database reconstructed as synthetic v5 by enumerated fixture-only changes; real non-superuser CLI v5-to-v6 DDL path and repeat via file credentials; not historical-writer evidence, rollback instructions, production host or cross-version PostgreSQL qualification')


if __name__ == '__main__':
    os.umask(0o077)
    f = offline.service.Fixture()
    previous = offline.OfflineRehearsal(f)
    upgrade = Upgrade(f, previous)
    failure = None
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        f.preflight()
        previous.preflight()
        upgrade.preflight()
        f.install()
        f.exercise()
        previous.exercise()
        upgrade.exercise()
    except BaseException as error:
        failure = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            f.cleanup()
        except BaseException as error:
            failure = (failure or '') + '; cleanup: ' + type(error).__name__ + ': ' + str(error)
    if failure:
        (upgrade.output / 'failure.json').write_text(json.dumps(dict(status='S33_UPGRADE_REHEARSAL_FAILED', failure=failure,
            cases=upgrade.cases, commands=upgrade.commands, transient_diagnostics=upgrade.transient_diagnostics), indent=2) + '\n')
        raise SystemExit('S33_UPGRADE_REHEARSAL_FAILED: ' + failure)
    base, earlier = f.proof(), previous.proof()
    package = json.loads((f.workspace / 'systemd-package-verification.json').read_text())
    checker.verify_core(earlier, base, package)
    (upgrade.output / 'base-profile-proof.json').write_text(json.dumps(base, indent=2) + '\n')
    (upgrade.output / 'offline-proof.json').write_text(json.dumps(earlier, indent=2) + '\n')
    result = upgrade.proof()
    accounting_bytes = (json.dumps(upgrade.accounting_input, indent=2) + '\n').encode()
    assert all(value.encode() not in accounting_bytes for value in [f.database_url, f.owner_password, f.viewer_password] + f.password_history)
    assert b'BEGIN PRIVATE KEY' not in accounting_bytes
    result['accounting_input_sha256'] = offline.service.digest(accounting_bytes)
    (upgrade.output / 'accounting-proof.json').write_bytes(accounting_bytes)
    (upgrade.output / 'proof.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(status=result['status'], source_commit=f.source, cases=len(upgrade.cases),
        previous_profile_consistency='S32_LIVE_OFFLINE_OBSERVATIONS_PASS')))
