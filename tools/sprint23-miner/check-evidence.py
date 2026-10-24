"""Check the fixed saved 1500-event observation, without Java or subprocesses.

Run from the repository root: ZIP EXISTING_EMPTY_OUTPUT_DIRECTORY.
The fixed archive, projection and auditor pins are independent of ZIP metadata.
"""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import zipfile

ROOT = Path(__file__).absolute().parents[2]
BUNDLE = 'c571d7b3c48d6df58dae8147f2afd94f1897af3b5ced14086ac29727db5c6148'
MANIFEST = 'bd4a03849189e65120ef74fbff435bf3639c5c9d7f518b8dedea5e8fcc1098a1'
AUDITOR = '238ea922f4967a4fde5d9fe1308ce9d152f104c2ab69caf11597e261252f82d7'


def need(ok, why):
    if not ok:
        raise ValueError(why)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def bounded_path(value):
    path = Path(os.path.abspath(value))
    need(path.is_relative_to(ROOT), 'outside_workspace')
    relative = path.relative_to(ROOT)
    current = path
    while True:
        info = current.lstat()
        need(not current.is_symlink() and not getattr(info, 'st_file_attributes', 0) & 1024,
             'reparse_path')
        if current == ROOT:
            break
        current = current.parent
    need(path.resolve(strict=True) == ROOT.resolve(strict=True) / relative,
         'resolved_workspace_path_mismatch')
    return path


def check(bundle, output):
    need(Path.cwd().absolute() == ROOT, 'run_from_repository_root')
    bundle, output = bounded_path(bundle), bounded_path(output)
    need(output.is_dir() and not any(output.iterdir()), 'fresh_empty_output')
    need(bundle.is_file() and bundle.stat().st_size <= 1024*1024, 'bundle_size')
    with bundle.open('rb') as stream:
        data = stream.read(1024*1024+1)
    need(len(data) == 37822 and digest(data) == BUNDLE, 'bundle_sha256')
    cached = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        need(len(entries) == 25, 'exact_member_count')
        need(sum(entry.file_size for entry in entries) == 1047921, 'declared_expanded_size')
        names = [entry.filename for entry in entries]
        need(len(set(name.casefold() for name in names)) == 25, 'unique_member_names')
        for entry in entries:
            name = entry.filename
            parts = PurePosixPath(name).parts
            need(bool(re.fullmatch(r'[A-Za-z0-9._/-]+', name)) and parts
                 and name == PurePosixPath(name).as_posix()
                 and not name.startswith('/') and all(p not in ('.', '..') for p in parts),
                 'safe_member_path')
            need(not entry.is_dir() and not entry.flag_bits & 1
                 and stat.S_IFMT(entry.external_attr >> 16) in (0, stat.S_IFREG)
                 and not entry.external_attr & 1024
                 and entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                 'regular_unencrypted_member')
            need(entry.file_size <= 2*1024*1024, 'member_size')
            value = archive.read(entry)  # Full CRC check before any extraction.
            need(len(value) == entry.file_size, 'member_length')
            cached[name] = value
        need(sum(map(len, cached.values())) == 1047921, 'expanded_size')
    need(digest(cached['public-projection.json']) == MANIFEST, 'projection_manifest_sha256')
    manifest = json.loads(cached['public-projection.json'])
    rows = manifest['files']
    need(len(rows) == 24 and len({r['path'] for r in rows}) == 24
         and set(cached) == {r['path'] for r in rows} | {'public-projection.json'},
         'exact_manifest_members')
    for row in rows:
        value = cached[row['path']]
        need(len(value) == row['published_bytes']
             and digest(value) == row['published_sha256'], 'published_member_identity')
    auditor = bounded_path(ROOT/'tools/sprint23-miner/audit-public.py')
    with auditor.open('rb') as stream:
        auditor_bytes = stream.read(65537)
    need(len(auditor_bytes) <= 65536 and digest(auditor_bytes) == AUDITOR, 'auditor_source_pin')
    for name, value in cached.items():
        destination = output.joinpath(*PurePosixPath(name).parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        bounded_path(destination.parent)
        with destination.open('xb') as stream:
            stream.write(value)
    spec = importlib.util.spec_from_file_location('fixed_scale_public_auditor', auditor)
    module = importlib.util.module_from_spec(spec)
    exec(compile(auditor_bytes, str(auditor), 'exec'), module.__dict__)
    result = output/'public-audit.json'
    previous = sys.argv
    try:
        sys.argv = [str(auditor), str(output/'miner-performance/scale-linear-1500.xes'),
                    str(output/'miner-performance'), str(result),
                    '--oracle', str(ROOT/'tools/oracle/audit-miner-benchmark-evidence.py'),
                    '--semantic', str(ROOT/'tools/oracle/audit-miner-performance.py'),
                    '--reference', str(ROOT/'fixtures/quality-miner/linear.bpmn'),
                    '--projection', str(output/'public-projection.json'),
                    '--ownership-review', str(output/'miner-audit/independent-audit.json')]
        module.main()
    finally:
        sys.argv = previous
    return {'status': 'FIXED_SAVED_SCALE_BUNDLE_AND_FULL_PUBLIC_AUDIT_PASS',
            'bundle_sha256': BUNDLE, 'members': 25, 'expanded_bytes': 1047921,
            'public_audit_sha256': digest(result.read_bytes()),
            'private_ownership_replayed': False, 'new_engine_execution': False}


if __name__ == '__main__':
    need(len(sys.argv) == 3, 'usage: ZIP EXISTING_EMPTY_OUTPUT_DIRECTORY')
    print(json.dumps(check(Path(sys.argv[1]), Path(sys.argv[2])), sort_keys=True))
