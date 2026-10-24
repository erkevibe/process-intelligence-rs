"""Publish only bounded synthetic alignment artifacts; copy original bytes unchanged.

Authoring this publisher is not permission to execute it or to accept the experiment.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat

CORPUS_SHA = 'fab7e1952bf5fab56c210023cd6d8b13fa4e19874ed5762330c78bbda68ce075'
MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
SOURCE_FILES = ['examples/discovery_fitness.rs', 'tests/sprint18_fitness.rs',
                'fixtures/discovery-fitness/corpus.json', 'Cargo.lock',
                'tools/sprint18/alignment-public-evidence.py',
                'tools/oracle/verify-alignment-evidence.py']
PROCESS_FIELDS = {'native_exit', 'stdout_complete', 'stderr_complete', 'output_limit',
                  'capture_fault', 'drain_timeout', 'stdout_bytes_persisted',
                  'stderr_bytes_persisted', 'stdout_sha256', 'stderr_sha256',
                  'program_sha256', 'started_utc', 'completed_utc',
                  'native_creation_utc', 'pid', 'rayon_threads', 'status',
                  'fmt_native_exit', 'test_native_exit', 'build_native_exit',
                  'full_source_unchanged', 'executable_sha256', 'observer_sha256',
                  'source_archive_sha256', 'source_commit'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def no_reparse(path):
    path = Path(os.path.abspath(path))
    for part in [path, *path.parents]:
        if part.exists() or part.is_symlink():
            info = part.lstat()
            require(not stat.S_ISLNK(info.st_mode) and
                    not getattr(info, 'st_file_attributes', 0) & 1024,
                    'reparse_or_symlink')
    return path


def read_bytes(path):
    path = no_reparse(path)
    require(path.is_file() and path.stat().st_size <= MAX_FILE, 'input_file_limit')
    data = path.read_bytes()
    require(len(data) <= MAX_FILE, 'input_file_grew')
    return data


def load(data):
    return json.loads(data.decode('utf-8-sig'), object_pairs_hook=unique_pairs)


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def process_summary(value):
    require(isinstance(value, dict), 'process_summary_object')
    result = {}
    for key in sorted(PROCESS_FIELDS):
        if key in value:
            item = value[key]
            require(isinstance(item, (str, int, bool)) or item is None,
                    'process_summary_scalar')
            if isinstance(item, str):
                require(not re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]|\\\\|/(?:Users|home)/', item),
                        'private_process_path')
            result[key] = item
    for key in ['native', 'fmt', 'test', 'build']:
        if isinstance(value.get(key), dict):
            result[key] = process_summary(value[key])
    require(result, 'empty_process_summary')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--source-root', type=Path)
    parser.add_argument('--nets', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--process-summary', action='append', default=[],
                        help='LABEL=PATH; original summary hash retained, private paths removed')
    args = parser.parse_args()
    workspace = no_reparse(args.workspace).resolve()
    output = no_reparse(args.output)
    require(output.resolve().is_relative_to(workspace) and output != workspace,
            'output_must_be_fresh_under_workspace')
    require(not output.exists(), 'output_already_exists')
    require(re.fullmatch(r'[0-9a-fA-F]{40}', args.source_commit), 'source_commit')
    source_root = no_reparse(args.source_root or workspace)
    corpus = read_bytes(source_root / 'fixtures/discovery-fitness/corpus.json')
    require(digest(corpus) == CORPUS_SHA, 'frozen_corpus_hash')
    bundle_bytes = read_bytes(args.nets / 'bundle.json')
    bundle = load(bundle_bytes)
    require(bundle['corpus_sha256'].lower() == CORPUS_SHA and
            bundle['phase'] == 'mine_only_no_alignment', 'bundle_binding')
    result_bytes = read_bytes(args.results)
    result = load(result_bytes)
    require(result['bundle_sha256'].lower() == digest(bundle_bytes) and
            result['corpus_sha256'].lower() == CORPUS_SHA and
            result['phase'] == 'align_only_no_discovery', 'result_binding')
    files = {'corpus.json': corpus, 'bundle.json': bundle_bytes,
             'alignment-results.json': result_bytes}
    nets = bundle['nets']
    require(len(nets) == 3 and {row['id'] for row in nets} == {'A10', 'A11', 'A12'},
            'three_original_nets')
    for row in nets:
        case = row['id']
        for name, hash_key in [(f'{case}.net.json', 'net_sha256'),
                               (f'{case}.pnml', 'pnml_sha256'),
                               (f'{case}.training.json', 'training_sha256')]:
            if hash_key != 'training_sha256':
                key = 'net_file' if hash_key == 'net_sha256' else 'pnml_file'
                require(row[key] == name, 'artifact_basename')
            data = read_bytes(args.nets / name)
            require(digest(data) == row[hash_key].lower(), 'original_artifact_hash')
            files['nets/' + name] = data
    for name, data in files.items():
        require(not re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]|\\\\|/(?:Users|home)/',
                              data.decode('utf-8-sig')), 'private_path_in_' + name)
    summaries = []
    labels = set()
    for argument in args.process_summary:
        label, separator, raw_path = argument.partition('=')
        require(separator and re.fullmatch(r'[a-z0-9-]{1,40}', label) and label not in labels,
                'process_summary_label')
        labels.add(label)
        raw = read_bytes(Path(raw_path))
        safe = process_summary(load(raw))
        summaries.append({'label': label, 'original_sha256': digest(raw),
                          'original_bytes': len(raw), 'selected_fields': safe})
    require({'build', 'mine', 'align'} <= labels, 'build_mine_align_process_summaries_required')
    source_pins = []
    for name in SOURCE_FILES:
        root = workspace if name.startswith('tools/') else source_root
        data = read_bytes(root / name)
        source_pins.append({'path': name, 'sha256': digest(data), 'bytes': len(data)})
    example_sha = next(row['sha256'] for row in source_pins if row['path'] == 'examples/discovery_fitness.rs')
    require(bundle['observer_source_sha256'] == result['observer_source_sha256'] == example_sha,
            'actual_frozen_observer_source_required')
    provenance = {'source_commit': args.source_commit.lower(),
                  'scope': load(corpus)['scope'],
                  'original_numeric_lexemes': 'All corpus/bundle/net/PNML/training/result bytes copied unchanged',
                  'process_summary_policy': 'Allowlisted fields only; original full-summary hashes retained; no console or binaries',
                  'source_files': source_pins,
                  'process_summaries': summaries,
                  'not_acceptance': True}
    files['provenance.json'] = (json.dumps(provenance, ensure_ascii=False, indent=2) + '\n').encode()
    require(len(files) <= 20 and sum(map(len, files.values())) <= MAX_TOTAL, 'aggregate_limit')
    manifest = {'schema_version': 1, 'kind': 'FINITE_PINNED_ALPHA_PETRI_ALIGNMENT_EVIDENCE',
                'scope': load(corpus)['scope'], 'corpus_sha256': CORPUS_SHA,
                'files': [{'path': name, 'sha256': digest(data), 'bytes': len(data)}
                          for name, data in sorted(files.items())],
                'not_acceptance': True}
    output.mkdir(parents=False)
    for name, data in files.items():
        target = output / name
        target.parent.mkdir(exist_ok=True)
        with target.open('xb') as stream:
            stream.write(data)
    with (output / 'manifest.json').open('xb') as stream:
        stream.write((json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode())
    print(json.dumps({'status': 'PUBLISHED_NOT_ACCEPTED', 'files': len(files) + 1,
                      'manifest_sha256': digest((output / 'manifest.json').read_bytes())}))


if __name__ == '__main__':
    main()
