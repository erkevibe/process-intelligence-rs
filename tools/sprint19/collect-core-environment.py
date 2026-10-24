"""Publish hashes and explicit metadata from the actual Core diagnostic build only."""
import argparse
import hashlib
import json
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size < 4 * 1024 * 1024
    return path.read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    root = workspace / '.local/sprint19/root'
    config_bytes = read(root / 'prep02/core-compile-config01.json')
    assert digest(config_bytes) == '1c98b65a084d9e217347f9ad30b8595ac28c043e023fc42dd35a214ea1e13bf0'
    config = json.loads(config_bytes)
    proof_bytes = read(root / 'core-compile01/core-build-proof.json')
    assert digest(proof_bytes) == '29dfd5d544e177bb3da5b08be82f30863fa0f32a577ef8aec6f9ff931a45704f'
    proof = json.loads(proof_bytes)
    assert proof['status'] == 'ACTUAL_OWN_JAVA_CLASSES_COMPILED_NO_R5_ENGINE_EXECUTION'
    jdk = workspace / '.local/sprint03/oracle/jdk/jdk-11.0.32.1+1'
    jdk_rows = []
    for pin in config['pins']:
        path = Path(pin['path']).resolve()
        if path.is_relative_to(jdk):
            data = path.read_bytes()
            assert digest(data) == pin['sha256'].lower()
            jdk_rows.append({'path': path.relative_to(jdk).as_posix(), 'bytes': len(data), 'sha256': digest(data)})
    assert len(jdk_rows) == 504 and len({row['path'] for row in jdk_rows}) == 504
    assert {path.relative_to(jdk).as_posix() for path in jdk.rglob('*') if path.is_file()} == {row['path'] for row in jdk_rows}
    sources = []
    for row in proof['java_sources']:
        path = Path(row['path'])
        assert digest(read(path)) == row['sha256'].lower()
        sources.append({'path': path.relative_to(root / 'frozen02').as_posix(), 'sha256': row['sha256'].lower()})
    for row in proof['class_files']:
        data = read(Path(proof['classes']) / row['path'])
        assert len(data) == row['bytes'] and digest(data) == row['sha256'].lower()
    native = []
    for name in ['javac', 'command']:
        record_bytes = read(root / 'core-compile01' / (name + '.process.json'))
        record = json.loads(record_bytes)
        assert record['native_exit'] == 0 and record['stdout_complete'] and record['stderr_complete']
        for channel in ['stdout', 'stderr']:
            data = read(root / 'core-compile01' / (name + '.' + channel))
            assert digest(data) == record[channel + '_sha256'].lower()
            assert len(data) == record[channel + '_bytes_persisted']
        record['program'] = Path(record['program']).name
        native.append({'label': name, 'original_record_sha256': digest(record_bytes), 'record': record})
    result = {
        'schema_version': 1,
        'kind': 'EXPLICIT_DERIVED_ACTUAL_CORE_DIAGNOSTIC_BUILD_METADATA_NOT_A_NATIVE_ENVIRONMENT',
        'compiled_source_commit': config['source_commit'],
        'compiled_source_archive_sha256': config['source_archive_sha'].lower(),
        'canonical_core_commit': 'bbf24dfd43e72d6992392465f875a4367cbe792b',
        'canonical_build_proof_sha256': proof['canonical_proof_sha256'].lower(),
        'ordered_classpath_sha256': proof['classpath_sha256'].lower(),
        'canonical_counts': {'source_git_blobs': 5763, 'runtime_files': 285, 'ordered_classpath_entries': 189},
        'original_compile_config_sha256': digest(config_bytes),
        'original_build_proof_sha256': digest(proof_bytes),
        'java_sha256': proof['java_sha256'].lower(),
        'javac_sha256': proof['javac_sha256'].lower(),
        'java_sources': sources,
        'generated_classes': proof['class_files'],
        'existing_jdk_files': sorted(jdk_rows, key=lambda row: row['path']),
        'jdk_trust': 'Read-only existing previously accepted JDK11; current complete file hashes bind execution, not a fresh upstream authenticity verification.',
        'native_receipts': native,
        'native_receipt_projection': 'Only program absolute path replaced with basename; every other record field retained. Original full streams verified but not published.',
        'upstream_source_or_binary_payload_published': False,
        'no_new_engine_executed_by_collector': True,
    }
    text = json.dumps(result, ensure_ascii=True, indent=2) + '\n'
    assert 'C:\\\\Users\\\\' not in text and 'C:/Users/' not in text
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(text)
    print(json.dumps({'sha256': digest(args.output.read_bytes()), 'jdk_files': len(jdk_rows)}))


if __name__ == '__main__':
    main()
