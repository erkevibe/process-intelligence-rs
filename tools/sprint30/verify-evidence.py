#!/usr/bin/env python3
"""Strict selected-evidence integrity and independent accounting, not execution replay."""
import copy
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import sys
import tempfile

FILES = {'quota-records.json', 'quota-controls.json', 'migration-proof.json',
         'workflow-proof.json', 'recovery-proof.json', 'owner-http-proof.json', 'native-proof.json'}
spec = importlib.util.spec_from_file_location('s30_accounting', Path(__file__).with_name('audit-quota.py'))
accounting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accounting)
EXPECTED = json.loads(Path(__file__).with_name('evidence-expected.json').read_text())


def load(raw):
    return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=accounting.no_duplicates,
                      parse_constant=lambda _: (_ for _ in ()).throw(AssertionError('nonfinite JSON')))


def verify(root):
    manifest = load((root / 'manifest.json').read_bytes())
    assert set(manifest) == {'schema_version', 'scope', 'files'} and type(manifest['schema_version']) is int and manifest['schema_version'] == 1
    assert {p.name for p in root.iterdir()} == FILES | {'manifest.json'}
    assert len(manifest['files']) == len(FILES)
    seen = set()
    for row in manifest['files']:
        assert set(row) == {'path', 'bytes', 'sha256'}
        assert type(row['bytes']) is int and row['bytes'] >= 0 and re.fullmatch('[0-9a-f]{64}', row['sha256'])
        name = row['path']
        assert name in FILES and name not in seen
        seen.add(name)
        path = root / name
        assert not path.is_symlink() and path.is_file()
        raw = path.read_bytes()
        assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256']
    assert seen == FILES
    data = {name: load((root / name).read_bytes()) for name in FILES}
    result = accounting.verify(data['quota-records.json'])
    assert len(result['snapshots']) == 7
    controls = data['quota-controls.json']
    assert set(controls) == set(EXPECTED['control_keys']) | {'status'}
    assert controls['status'] == 'S30_QUOTA_CONTROLS_PASS' and all(controls[k] is True for k in EXPECTED['control_keys'])
    migration = data['migration-proof.json']
    assert migration['status'] == 'S30_POPULATED_V5_TO_V6_PASS'
    assert set(migration) == set(EXPECTED['migration_keys'])
    assert all(v is True for k, v in migration.items() if k not in ('status', 'payload_used'))
    assert type(migration['payload_used']) is int and migration['payload_used'] > 0
    workflow = data['workflow-proof.json']
    assert workflow['status'] == 'S30_QUOTA_WORKFLOWS_PASS' and workflow['owner_only_policy'] is True
    assert [v['case'] for v in workflow['cases']] == EXPECTED['workflow_cases']
    recovery = data['recovery-proof.json']
    assert recovery['status'] == 'S30_QUOTA_QUEUED_RECOVERY_PASS'
    assert [v['case'] for v in recovery['cases']] == EXPECTED['recovery_cases']
    for index, row in enumerate(recovery['cases']):
        if index % 2 == 0:
            assert set(row) == {'case', 'job', 'job_revision', 'payload_accounting_sha256'}
            assert type(row['job_revision']) is int and row['job_revision'] == 1
            assert re.fullmatch(r'job-[1-9][0-9]*', row['job']) and re.fullmatch('[0-9a-f]{64}', row['payload_accounting_sha256'])
        else:
            assert set(row) == {'case'}
    http = data['owner-http-proof.json']
    assert http['status'] == 'S30_QUOTA_OWNER_HTTP_PASS' and len(http['cases']) == 22
    assert all(v['outcome'] == 'pass' for v in http['cases'])
    assert [v['case'] for v in http['cases']] == EXPECTED['owner_cases']
    assert [dict(method=r['method'], path=r['path'], status=r['status']) for r in http['requests']] == EXPECTED['owner_requests']
    assert all(type(r['status']) is int for r in http['requests'])
    native = data['native-proof.json']
    assert native['status'] == 'S30_QUOTA_NATIVE_CORE_CLOSED' and native['user3131_untouched'] is True
    labels = {v['label'] for v in native['records']}
    assert len(labels) == len(native['records']) and labels == set(EXPECTED['native_labels'])
    for row in native['records']:
        assert row['stdout_complete'] is True and row['stderr_complete'] is True and row['source_status'] == 'captured'
        allowed = [0, 1, 2] if row['label'].startswith('ready-') else [1] if row['label'] == 'old-binary' else [137] if row['label'] == 'app-live' else [0]
        assert type(row['native_exit']) is int and row['native_exit'] in allowed
    by_label = {r['label']: r for r in native['records']}
    assert by_label['old-before']['stdout_sha256'] == by_label['old-after']['stdout_sha256']
    # Counterfactual: matching saved counters are insufficient when records change.
    changed = copy.deepcopy(data['quota-records.json'])
    changed['snapshots'][0]['records'][0]['document']['s30_counterfactual'] = 'x'
    try:
        accounting.verify(changed)
    except AssertionError:
        pass
    else:
        raise AssertionError('altered payload accepted')
    return dict(status='S30_SELECTED_EVIDENCE_PASS', snapshots=7, workflow_cases=14, recovery_cases=8,
                owner_http_cases=22, controls='manifest hashes and altered-payload accounting refusal',
                scope='integrity and logical accounting; native execution is retained evidence, not replayed')


def counterfactuals(root):
    for raw in [b'1e999', b'-1e999']:
        try:
            accounting.cost(load(raw))
        except AssertionError:
            pass
        else:
            raise AssertionError('nonfinite numeric overflow accepted')
    mutations = [
        ('quota-controls.json', lambda v: v.pop(EXPECTED['control_keys'][0])),
        ('migration-proof.json', lambda v: v.pop('repeat_no_change')),
        ('workflow-proof.json', lambda v: v['cases'][0].update(case='unrelated_case')),
        ('recovery-proof.json', lambda v: v['cases'].pop()),
        ('recovery-proof.json', lambda v: v['cases'][0].update(job_revision=True)),
        ('owner-http-proof.json', lambda v: v['cases'][0].update(case='unrelated_case')),
        ('owner-http-proof.json', lambda v: v['requests'][0].update(status=True)),
        ('native-proof.json', lambda v: v.update(records=[r for r in v['records'] if r['label'] != 'app-live'])),
        ('native-proof.json', lambda v: next(r for r in v['records'] if r['label'] == 'old-binary').update(native_exit=True)),
        ('quota-records.json', lambda v: v['snapshots'][0].update(payload_used=v['snapshots'][0]['payload_used']+1)),
    ]
    for name, mutate in mutations:
        with tempfile.TemporaryDirectory(prefix='s30-evidence-control-') as tmp:
            target = Path(tmp)
            for source in root.iterdir():
                assert source.is_file() and not source.is_symlink()
                (target / source.name).write_bytes(source.read_bytes())
            value = load((target / name).read_bytes())
            mutate(value)
            raw = (json.dumps(value, ensure_ascii=False) + '\n').encode()
            (target / name).write_bytes(raw)
            # Rehash changed evidence so rejection must come from semantic coverage.
            manifest = load((target / 'manifest.json').read_bytes())
            row = next(r for r in manifest['files'] if r['path'] == name)
            row.update(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
            (target / 'manifest.json').write_text(json.dumps(manifest))
            try:
                verify(target)
            except AssertionError:
                pass
            else:
                raise AssertionError('counterfactual accepted: ' + name)
    return len(mutations)


if __name__ == '__main__':
    root = Path(sys.argv[1]).resolve(strict=True)
    assert root.is_dir()
    result = verify(root)
    if sys.argv[2:] == ['--self-test']:
        result['rehash_semantic_counterfactuals_refused'] = counterfactuals(root)
        result['nonfinite_numeric_overflow_controls_refused'] = 2
    else:
        assert len(sys.argv) == 2
    print(json.dumps(result, sort_keys=True))
