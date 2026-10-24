#!/usr/bin/env python3
"""Check the actual tar payload and replay reports with its packaged Linux binary."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile

assert os.environ.get('GITHUB_ACTIONS') == 'true'
archive, destination, report = map(Path, sys.argv[1:])
assert not destination.exists()
destination.mkdir()
with tarfile.open(archive, 'r:gz') as source:
    names = set()
    for member in source.getmembers():
        path = PurePosixPath(member.name)
        assert not path.is_absolute() and '..' not in path.parts
        assert member.isdir() or member.isfile(), 'links/devices excluded'
        assert str(path) not in names
        names.add(str(path))
    source.extractall(destination, filter='data')
manifest = json.loads((destination / 'PACKAGE_MANIFEST.json').read_text())
assert set(manifest) == {'schema_version', 'source_commit', 'files'} and manifest['schema_version'] == 1
if os.environ.get('S30_EXPECTED_SOURCE'):
    assert manifest['source_commit'] == os.environ['S30_EXPECTED_SOURCE']
actual = {str(p.relative_to(destination)).replace(os.sep, '/') for p in destination.rglob('*') if p.is_file()}
expected = set()
for row in manifest['files']:
    assert set(row) == {'path', 'bytes', 'sha256'}
    path = PurePosixPath(row['path'])
    assert not path.is_absolute() and '..' not in path.parts and str(path) not in expected
    expected.add(str(path))
    raw = (destination / str(path)).read_bytes()
    assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256']
assert actual == expected | {'PACKAGE_MANIFEST.json'}
assert {'process-intelligence-rs', 'pi_convert', 'CANDIDATE_STATUS.md',
        'BUILD_ENVIRONMENT.json',
        'deploy/linux/Caddyfile', 'deploy/linux/process-intelligence.service',
        'docs/PROJECT_QUOTA_CONTRACT.md', 'docs/LINUX_TLS_DEPLOYMENT.md',
        'tools/sprint30/verify-evidence.py', 'evidence/sprint30/project-quota/manifest.json'} <= actual
assert not any(p.startswith('.local/') or p.endswith(('.key', '.dump')) for p in actual)
environment = json.loads((destination / 'BUILD_ENVIRONMENT.json').read_text())
assert environment['source_commit'] == manifest['source_commit'] and environment['system'] == 'Linux' and environment['machine'] == 'x86_64'
binary = (destination / 'process-intelligence-rs').resolve(strict=True)
env = {k: v for k, v in os.environ.items() if not k.startswith('PI_DATABASE_URL')}
results = []
for path in [report.resolve(strict=True), Path('evidence/sprint28/durable-discovery/browser-original-report.json').resolve(strict=True)]:
    completed = subprocess.run([str(binary), '--verify-quality-report', str(path)],
                               cwd=destination, env=env, capture_output=True, timeout=30, check=True)
    result = json.loads(completed.stdout)
    export = json.loads(path.read_bytes())
    assert set(result) == {'status', 'numeric_replay', 'author_signature_verified', 'method_sha256', 'input_model_sha256', 'input_variants_sha256'}
    assert result['status'] == 'quality_report_verified' and result['numeric_replay'] is True and result['author_signature_verified'] is False
    assert result['method_sha256'] == export['method_sha256']
    assert result['input_model_sha256'] == export['evaluation']['input_model_sha256']
    assert result['input_variants_sha256'] == export['evaluation']['input_variants_sha256']
    results.append(dict(report_sha256=hashlib.sha256(path.read_bytes()).hexdigest(), verification=result))
evidence = subprocess.run([sys.executable, '-I', '-B', 'tools/sprint30/verify-evidence.py', 'evidence/sprint30/project-quota'],
                          cwd=destination, check=True, timeout=30, capture_output=True)
evidence_result = json.loads(evidence.stdout)
assert evidence_result['status'] == 'S30_SELECTED_EVIDENCE_PASS'
downloaded = os.environ.get('S30_PACKAGE_DOWNLOADED') == 'yes'
print(json.dumps(dict(status='S30_DOWNLOADED_LINUX_PACKAGE_PASS' if downloaded else 'S30_EXTRACTED_LINUX_PACKAGE_PASS', source_commit=manifest['source_commit'],
    archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(), files=len(actual), reports=results,
    build_environment=environment,
    evidence_verification=evidence_result,
    scope='artifact downloaded in a separate Linux CI job' if downloaded else 'archive generated and extracted in CI; not a separately downloaded artifact or production install')))
