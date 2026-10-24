#!/usr/bin/env python3
"""Strict selected-evidence integrity and independent accounting, not execution replay."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

FILES = {'quota-records.json', 'quota-controls.json', 'migration-proof.json',
         'workflow-proof.json', 'owner-http-proof.json', 'native-proof.json'}
spec = importlib.util.spec_from_file_location('s30_accounting', Path(__file__).with_name('audit-quota.py'))
accounting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accounting)


def load(raw):
    return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=accounting.no_duplicates,
                      parse_constant=lambda _: (_ for _ in ()).throw(AssertionError('nonfinite JSON')))


def verify(root):
    manifest = load((root / 'manifest.json').read_bytes())
    assert set(manifest) == {'schema_version', 'scope', 'files'} and manifest['schema_version'] == 1
    assert {p.name for p in root.iterdir()} == FILES | {'manifest.json'}
    assert len(manifest['files']) == len(FILES)
    seen = set()
    for row in manifest['files']:
        assert set(row) == {'path', 'bytes', 'sha256'}
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
    assert controls.pop('status') == 'S30_QUOTA_CONTROLS_PASS' and controls and all(v is True for v in controls.values())
    migration = data['migration-proof.json']
    assert migration['status'] == 'S30_POPULATED_V5_TO_V6_PASS'
    assert all(v is True for k, v in migration.items() if k not in ('status', 'payload_used'))
    workflow = data['workflow-proof.json']
    assert workflow['status'] == 'S30_QUOTA_WORKFLOWS_PASS' and workflow['owner_only_policy'] is True
    assert len(workflow['cases']) == 14 and len({v['case'] for v in workflow['cases']}) == 14
    http = data['owner-http-proof.json']
    assert http['status'] == 'S30_QUOTA_OWNER_HTTP_PASS' and len(http['cases']) == 22
    assert all(v['outcome'] == 'pass' for v in http['cases'])
    native = data['native-proof.json']
    assert native['status'] == 'S30_QUOTA_NATIVE_CORE_CLOSED' and native['user3131_untouched'] is True
    labels = {v['label'] for v in native['records']}
    assert len(labels) == len(native['records']) and {'test-quota', 'test-workflow', 'test-migration', 'owner-http', 'old-before', 'old-after', 'old-binary', 'postgres-g1', 'pg-stop-g1'} <= labels
    for row in native['records']:
        assert row['stdout_complete'] is True and row['stderr_complete'] is True and row['source_status'] == 'captured'
        allowed = [0, 1, 2] if row['label'].startswith('ready-') else [1] if row['label'] == 'old-binary' else [137] if row['label'] == 'app-live' else [0]
        assert row['native_exit'] in allowed
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
    return dict(status='S30_SELECTED_EVIDENCE_PASS', snapshots=7, workflow_cases=14,
                owner_http_cases=22, controls='manifest hashes and altered-payload accounting refusal',
                scope='integrity and logical accounting; native execution is retained evidence, not replayed')


if __name__ == '__main__':
    root = Path(sys.argv[1]).resolve(strict=True)
    assert root.is_dir()
    print(json.dumps(verify(root), sort_keys=True))
