"""Publish exact synthetic historical-miner data; no new mining or metric runs."""
import argparse
import hashlib
import json
from pathlib import Path


def read(path):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('bounded_regular_source')
    value = path.read_bytes()
    if len(value) > 32 * 1024 * 1024:
        raise ValueError('source_grew')
    return value


def sha(value):
    return hashlib.sha256(value).hexdigest()


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode()


def collect(private, output):
    output.mkdir(parents=True, exist_ok=False)
    rows = []

    def save(name, data, source):
        if b'C:\\Users\\' in data or b'C:/Users/' in data:
            raise ValueError('local_path_not_public_measurement')
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(data)
        if read(target) != data:
            raise ValueError('copy_readback')
        rows.append({'path': name, 'bytes': len(data), 'sha256': sha(data), 'source': source})

    def copy(source, target):
        data = read(private / source)
        save(target, data, source)
        if read(private / source) != data:
            raise ValueError('private_source_changed')

    for source, target in [
            ('miner-score01/rust-metrics.json', 'rust-metrics.json'),
            ('miner-score01/reference-metrics.json', 'reference-metrics.json'),
            ('miner-comparison01/typed-comparison.json', 'typed-comparison.json'),
            ('miner-conservation01/conservation-and-equivalence.json', 'conservation-and-equivalence.json')]:
        copy(source, target)
    for source, target in [('miner-prepare01/prepared', 'prepared'),
                           ('miner-prepare01/reference-conversion', 'reference-conversion')]:
        for path in sorted((private / source).rglob('*')):
            if path.is_symlink():
                raise ValueError('reparse_source')
            if path.is_file():
                relative = path.relative_to(private / source).as_posix()
                copy(source + '/' + relative, target + '/' + relative)
    receipts = []
    for phase, labels in [
            ('miner-prepare01', ['project-original-xml', 'rust-prepare', 'pm4py-convert-original', 'command']),
            ('miner-score01', ['rust-score', 'pm4py-score', 'command'])]:
        for label in labels:
            data = read(private / phase / (label + '.process.json'))
            record = json.loads(data)
            if not (record['native_exit'] == 0 and record['stdout_complete'] and record['stderr_complete']
                    and not record['output_limit'] and not record['capture_fault'] and not record['drain_timeout']):
                raise ValueError('native_not_successfully_closed')
            projected = {key: value for key, value in record.items() if key != 'program'}
            projected['program_basename'] = record['program'].replace('\\', '/').rsplit('/', 1)[-1]
            receipts.append({'phase': phase, 'label': label,
                             'original_record_sha256': sha(data), 'record': projected})
    save('native-receipts.json', encode({'schema_version': 1,
         'projection': 'Exact non-program fields; absolute program path replaced by basename; original record SHA retained.',
         'receipts': receipts}), 'explicit_native_receipt_field_projection')
    save('provenance.json', encode({
        'schema_version': 1, 'compiled_source_commit': '75575480e645b663bfe58c8d9a82e4b681ca3da0',
        'compiled_source_archive_sha256': '31fd2fa8138aae543b7ed467c015d4029953eedea282826608494596489e4bf7',
        'observer_executable_sha256': 'a72e7f86631211b3440e8ffc685d392daad92106d4ba67e7da8948712877264b',
        'cohort_sha256': '6dac7a9b69d553590f342ed4b836140678a9f2c072cc806119f0ecc48ace208d',
        'reference_adapter_sha256': 'f652edc94f22845a91f2ce9c6e3dd2c55bca7e2e6c94345bbc2b3928d99bd9be',
        'unchanged_base_reference_adapter_sha256': '3088b0d864a21b5946aab207a3a1cf4d89204a817e468f9185c96b72a6a0fd9b',
        'core_commit': 'bbf24dfd43e72d6992392465f875a4367cbe792b',
        'pm4py_version': '2.7.17',
        'base_reference_environment_manifest_sha256': 'bc63c366aa7597c621a1cd59d06cbb4f58f48832bc99111ef57cb314175479e2',
        'scope': 'All eight immutable historical SplitMiner outcomes, six admitted training-only metric groups. No new miner run, held-out/generalization claim, raw product import or whole-R4 acceptance.'
    }), 'explicit_experiment_provenance')
    manifest = {'schema_version': 1, 'files': sorted(rows, key=lambda row: row['path']),
                'logical_bytes': sum(row['bytes'] for row in rows), 'manifest_excludes_itself': True,
                'not_acceptance': True}
    with (output / 'manifest.json').open('xb') as stream:
        stream.write(encode(manifest))
    return {'files': len(rows), 'bytes': manifest['logical_bytes'],
            'manifest_sha256': sha(read(output / 'manifest.json'))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('private_root', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(json.dumps(collect(args.private_root, args.output)))


if __name__ == '__main__':
    main()
