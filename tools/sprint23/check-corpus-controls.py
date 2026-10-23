"""Three finite saved-corpus counterfactuals; no child, converter or network."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

BATCH_SHA = '08D8BDF435FE2D9E0BAA334E1CB6E52B891BDE7A8824AF7E73715E7E7E932FC5'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('emitted', type=Path)
    p.add_argument('fixtures', type=Path, help='existing empty protected Root directory')
    p.add_argument('--batch', type=Path, required=True)
    p.add_argument('--auditor', type=Path, required=True)
    p.add_argument('--oracle', type=Path, required=True)
    p.add_argument('--corpus', type=Path, required=True)
    p.add_argument('--source-root', type=Path, required=True)
    p.add_argument('--codec-sha', required=True)
    args = p.parse_args()
    start = time.monotonic()
    def need(ok, why):
        if not ok:
            raise ValueError(why)
        if time.monotonic()-start >= 120:
            raise ValueError('controls_deadline')
    def ordinary(path):
        root = args.source_root.absolute()
        path = path.absolute()
        need('..' not in path.parts and path.is_relative_to(root), 'contained')
        current = root
        for part in (None, *path.relative_to(root).parts):
            if part is not None:
                current /= part
            st = current.lstat()
            need(not current.is_symlink() and not getattr(st, 'st_file_attributes', 0) & 1024,
                 'no_reparse')
        return path
    def read(path, cap):
        path = ordinary(path)
        need(path.is_file() and path.stat().st_size <= cap, 'file_bound')
        with path.open('rb') as stream:
            raw = stream.read(cap+1)
        need(len(raw) <= cap, 'read_bound')
        return raw
    need(hashlib.sha256(read(args.batch, 128*1024)).hexdigest().upper() == BATCH_SHA, 'batch_pin')
    spec = importlib.util.spec_from_file_location('corpus_batch_under_test', args.batch)
    batch = importlib.util.module_from_spec(spec); spec.loader.exec_module(batch)
    ordinary(args.fixtures)
    need(args.fixtures.is_dir() and not any(args.fixtures.iterdir()), 'fresh_fixtures')
    original = {}
    for path in ordinary(args.emitted).iterdir():
        need(len(original) < 128 and path.is_file(), 'flat_count')
        original[path.name] = read(path, 4*1024*1024)
    need(sum(map(len, original.values())) <= 512*1024, 'small_cohort_control_bound')
    original_index = json.loads(original['index.json'])
    results, total = [], 0
    cases = [('index_hash', 'artifact_pin'), ('typed_report', 'outer_schema_type'),
             ('extra_file', 'exact_emitted_files_and_9_inverse')]
    for name, expected in cases:
        root = args.fixtures/name; root.mkdir()
        source, output = root/'emitted', root/'audit'
        source.mkdir(); output.mkdir()
        changed = dict(original)
        index = json.loads(original['index.json'])
        if name == 'index_hash':
            index['cases'][0]['default_report']['sha256'] = '0'*64
        elif name == 'typed_report':
            entry = index['cases'][0]['default_report']
            value = json.loads(changed[entry['file']])
            value['schema_version'] = True
            raw = json.dumps(value, ensure_ascii=False).encode()
            changed[entry['file']] = raw
            entry['bytes'], entry['sha256'] = len(raw), hashlib.sha256(raw).hexdigest()
        else:
            changed['unexpected.bin'] = b'not-in-index'
        changed['index.json'] = json.dumps(index, ensure_ascii=False).encode()
        for file, raw in changed.items():
            need('/' not in file and '\\' not in file and ':' not in file, 'flat_name')
            total += len(raw); need(total <= 2*1024*1024, 'staging_cap')
            with (source/file).open('xb') as stream:
                stream.write(raw)
        argv = [str(args.batch), str(source), str(output), '--auditor', str(args.auditor),
                '--oracle', str(args.oracle), '--corpus', str(args.corpus),
                '--source-root', str(args.source_root), '--codec-sha', args.codec_sha]
        previous = sys.argv; reason = None
        try:
            sys.argv = argv
            batch.START = time.monotonic()
            batch.main()
        except ValueError as error:
            reason = str(error)
        finally:
            sys.argv = previous
        need(reason == expected, 'specific_rejection_'+name)
        for file in output.iterdir():
            total += file.stat().st_size
        need(total <= 2*1024*1024, 'all_control_output_cap')
        results.append({'case': name, 'rejected': True, 'reason': reason})
    for file, raw in original.items():
        need(read(args.emitted/file, 4*1024*1024) == raw, 'original_unchanged')
    proof = {'status': 'FINITE_CORPUS_COUNTERFACTUALS_PASS', 'rejections': results,
             'original_index_sha256': hashlib.sha256(original['index.json']).hexdigest(),
             'staged_and_audit_bytes': total, 'native_execution_verified': False,
             'limits': ['Three specific saved mutations only; original positive cohort is a separate run.']}
    with (args.fixtures/'controls-proof.json').open('x', encoding='utf-8') as stream:
        json.dump(proof, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
