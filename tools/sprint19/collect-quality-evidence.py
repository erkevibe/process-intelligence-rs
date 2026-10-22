"""Collect exact synthetic quality artifacts and explicitly projected native receipts.

Creates a new public directory only. Never edits private originals or rewrites
measurement JSON. Native receipts omit local absolute paths; their original-byte
hashes remain recorded. This is evidence collection, not scientific acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('bounded_regular_source_required')
    data = path.read_bytes()
    if len(data) > 32 * 1024 * 1024:
        raise ValueError('source_grew')
    return data


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode()


def collect(private, output):
    output.mkdir(parents=True, exist_ok=False)
    members = []

    def save(relative, data, source=None):
        if b'C:\\Users\\' in data or b'C:/Users/' in data:
            raise ValueError('local_path_not_public_measurement')
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as stream:
            stream.write(data)
        if read(path) != data:
            raise ValueError('copy_readback')
        members.append({'path': relative, 'bytes': len(data), 'sha256': digest(data),
                        'source': source or 'explicit_derived_metadata'})

    def copy(source, relative):
        data = read(private / source)
        save(relative, data, source)
        if digest(read(private / source)) != digest(data):
            raise ValueError('private_source_changed')

    for source, relative in [
            ('quality-score02/rust-metrics.json', 'rust-metrics.json'),
            ('quality-score02/reference-metrics.json', 'reference-metrics.json'),
            ('metric-comparison02/typed-comparison.json', 'typed-comparison.json'),
            ('conservation01/conservation-and-equivalence.json', 'conservation-and-equivalence.json'),
            ('reference-lock01/official-wheel-lock.json', 'reference/official-wheel-lock.json'),
            ('reference-lock01/requirements.lock', 'reference/windows-python313-requirements.lock'),
            ('reference-install01/pm4py-original-files.json', 'reference/original-pm4py-files.json')]:
        copy(source, relative)
    for source, destination in [('quality-prepare01/prepared', 'prepared'),
                                ('quality-prepare01/reference-conversion', 'reference-conversion')]:
        for path in sorted((private / source).rglob('*')):
            if path.is_symlink():
                raise ValueError('reparse_source_refused')
            if path.is_file():
                name = path.relative_to(private / source).as_posix()
                copy(source + '/' + name, destination + '/' + name)

    receipts = []
    phases = [('quality-build01', ['fmt', 'quality-tests', 'quality-build', 'quality-clippy', 'command']),
              ('quality-prepare01', ['rust-prepare', 'pm4py-convert', 'command']),
              ('quality-score02', ['rust-score', 'pm4py-score', 'command'])]
    for phase, labels in phases:
        for label in labels:
            record_bytes = read(private / phase / (label + '.process.json'))
            record = json.loads(record_bytes)
            if not (record['native_exit'] == 0 and record['stdout_complete'] and record['stderr_complete']
                    and not record['output_limit'] and not record['capture_fault'] and not record['drain_timeout']):
                raise ValueError('native_capture_not_successfully_closed')
            # All non-path fields are copied exactly, including native identities,
            # real times, EOF, captured byte counts and each complete stream hash.
            projected = {key: value for key, value in record.items() if key != 'program'}
            projected['program_basename'] = record['program'].replace('\\', '/').rsplit('/', 1)[-1]
            receipts.append({'phase': phase, 'label': label,
                             'original_record_sha256': digest(record_bytes), 'record': projected})
    save('native-receipts.json', encode({'schema_version': 1,
          'projection': 'Exact original non-program fields; program absolute path replaced by basename; original record SHA retained.',
          'receipts': receipts}))
    comparison = json.loads(read(output / 'typed-comparison.json'))
    prepared = json.loads(read(output / 'prepared/bundle.json'))
    provenance = {'schema_version': 1, 'compiled_rust_source_commit': 'db1fb4f42e9dfa2f0af7f268ced01554e4402768',
                  'compiled_rust_archive_sha256': '6cb19913d3655685552531b7f912b49c3c1d01d6faefa1d552f2711f31b45c01',
                  'observer_executable_sha256': '20e1eedb193169b0a19ebd98a8a5191358618e205fa5ddd131052dded366dd4b',
                  'reference_adapter_sha256': '3088b0d864a21b5946aab207a3a1cf4d89204a817e468f9185c96b72a6a0fd9b',
                  'pm4py_version': '2.7.17',
                  'pm4py_wheel_sha256': '77fa0bbbe8284f0c94d577163213b5d4758bcf309a0266d34278a4476df28686',
                  'method_sha256': prepared['method_sha256'], 'corpus_sha256': comparison['corpus_sha256'],
                  'artifact_case_rows': comparison['artifact_case_rows'],
                  'group_status_counts': comparison['group_status_counts'],
                  'frozen_negative_reason_failures': comparison['negative_reason_failures'],
                  'scope': 'Synthetic diagnostic models and logs. Original refusals/caps/failed reason predictions retained. No full R4 acceptance or runtime 0.7.5 change.',
                  'bootstrap_failures': ['Initial binary-only pip resolution refused pydotplus; original failure retained privately, reviewed unmodified sdist built offline.',
                                         'Initial score attempt refused an unprotected inherited ACL before either metric engine; same-SID ACL protected, all input bytes unchanged, successful run is score02.']}
    save('provenance.json', encode(provenance))
    manifest = {'schema_version': 1, 'status': 'EXACT_PUBLIC_MEASUREMENT_ARTIFACTS_WITH_EXPLICIT_METADATA_PROJECTIONS',
                'files': sorted(members, key=lambda row: row['path']),
                'logical_bytes': sum(row['bytes'] for row in members),
                'manifest_excludes_itself': True, 'not_acceptance': True}
    with (output / 'manifest.json').open('xb') as stream:
        stream.write(encode(manifest))
    return {'files': len(members), 'bytes': manifest['logical_bytes'],
            'manifest_sha256': digest(read(output / 'manifest.json'))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('private_root', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(json.dumps(collect(args.private_root, args.output)))


if __name__ == '__main__':
    main()
