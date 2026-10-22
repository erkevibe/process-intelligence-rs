"""Explicit bounded projection selection for closed synthetic preflight controls."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

workspace, source, manifest, attrs = map(Path, sys.argv[1:5])
policy = workspace / 'tools/sprint21/project-public-evidence.py'
assert hashlib.sha256(policy.read_bytes()).hexdigest().upper() == '29576670CB09D054F366B1DEE981CC56305B6B1A0C8AD1BC48600114D9B8109F'
spec = importlib.util.spec_from_file_location('unchanged_projection_policy', policy)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
started = time.monotonic()
assert not manifest.exists()
assert json.loads((source / 'result.json').read_text())['status'] == 'COMPLETED'
entries = []
total = 0
files = sorted(source.rglob('*'))
assert len(files) <= 128
for file in files + [attrs]:
    assert time.monotonic() - started < 20
    p.chain(file, workspace)
    if file.is_dir():
        continue
    raw = p.bounded(file, 1024 * 1024, workspace)
    total += len(raw)
    assert total <= 2 * 1024 * 1024
    name = '.gitattributes' if file == attrs else file.relative_to(source).as_posix()
    row = dict(source=file.relative_to(workspace).as_posix(), sha256=p.sha(raw),
               public_path=name, mode='bytes')
    if file.name == 'fixture-config.json':
        row.update(mode='omit', reason='Private synthetic configuration paths omitted; original content identity retained')
    elif file.suffix == '.json':
        value = p.parse(raw)
        pointers = ['/program'] if isinstance(value, dict) and isinstance(value.get('program'), str) and p.ABSOLUTE.search(value['program']) else []
        projected = p.transform(value, set(pointers), workspace, Path.home().absolute(), set())
        p.machine_leak((p.emit(projected) + '\n').encode(), workspace, Path.home().absolute())
        row.update(mode='json_paths' if pointers else 'bytes', json_pointers=pointers)
    else:
        p.machine_leak(raw, workspace, Path.home().absolute())
    entries.append(row)
for row in entries:
    assert time.monotonic() - started < 20
    assert p.sha(p.bounded(workspace / row['source'], 1024 * 1024, workspace)) == row['sha256']
with manifest.open('x', encoding='utf-8', newline='\n') as stream:
    json.dump({'schema_version': 1, 'entries': entries}, stream, indent=2)
print(json.dumps({'entries': len(entries), 'omitted': sum(row['mode'] == 'omit' for row in entries),
                  'source_bytes': total, 'manifest_sha256': p.sha(manifest.read_bytes())}))
