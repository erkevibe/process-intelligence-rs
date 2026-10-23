"""Finite saved corpus audit; no converter, subprocess, network or native launch.

One emitter process is separate provenance. Repeated calls below execute only the
hard-pinned independent Python auditor against original frozen manual fixtures.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import time

AUDIT_SHA = '048A57750159B49D20E3CCABB02ACB1A7C4320A1C676DAB1B91291CF7114B802'
CORPUS_SHA = '621dc9106835eb3274659a08f033da4b74ef7cce9a58846e4b01788c866cfe34'
START = time.monotonic()


def need(ok, why):
    if not ok:
        raise ValueError(why)
    if time.monotonic() - START > 120:
        raise ValueError('batch_deadline')


def safe(path, anchor):
    need('..' not in path.parts and '..' not in anchor.parts, 'parent_component')
    path, anchor = path.absolute(), anchor.absolute()
    need(path.is_relative_to(anchor), 'contained_path')
    current = anchor
    for part in (None, *path.relative_to(anchor).parts):
        if part is not None:
            current /= part
        st = current.lstat()
        need(not current.is_symlink() and not getattr(st, 'st_file_attributes', 0) & 0x400,
             'reparse_refused')
    return path


def read(path, anchor, cap):
    path = safe(path, anchor)
    need(path.is_file() and path.stat().st_size <= cap, 'file_cap')
    with path.open('rb') as stream:
        raw = stream.read(cap + 1)
    need(len(raw) <= cap, 'read_cap')
    return raw


def main():
    p = argparse.ArgumentParser()
    p.add_argument('emitted', type=Path)
    p.add_argument('output', type=Path, help='existing fresh private directory')
    p.add_argument('--auditor', type=Path, required=True)
    p.add_argument('--oracle', type=Path, required=True)
    p.add_argument('--corpus', type=Path, required=True)
    p.add_argument('--source-root', type=Path, required=True)
    p.add_argument('--codec-sha', required=True)
    args = p.parse_args()
    workspace = args.source_root.absolute()
    emitted = safe(args.emitted, workspace)
    output = safe(args.output, workspace)
    need(emitted.is_dir() and output.is_dir() and not any(output.iterdir()), 'fresh_output')
    need(emitted != output and not output.is_relative_to(emitted), 'disjoint_output')
    auditor_raw = read(args.auditor, workspace, 128*1024)
    need(hashlib.sha256(auditor_raw).hexdigest().upper() == AUDIT_SHA, 'auditor_pin')
    spec = importlib.util.spec_from_file_location('independent_compact_audit', args.auditor)
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    corpus_raw = read(args.corpus, workspace, 512*1024)
    need(hashlib.sha256(corpus_raw).hexdigest() == CORPUS_SHA, 'corpus_pin')
    corpus = audit.loads(corpus_raw)
    cases = [c for c in corpus['cases'] if (c['from'], c['to']) in
             {('xes', 'csv'), ('csv', 'xes')}]
    need(len(cases) == 29 and len({c['id'] for c in cases}) == 29, 'fixed_29_cases')
    index = audit.loads(read(emitted/'index.json', workspace, 256*1024))
    need(set(index) == {'status', 'corpus_sha256', 'log_cases', 'actual_inverse_calls', 'cases', 'limits'}
         and index['status'] == 'ACTUAL_PRODUCT_API_CORPUS_ARTIFACTS_REQUIRE_INDEPENDENT_AUDIT'
         and index['corpus_sha256'] == CORPUS_SHA
         and type(index['log_cases']) is int and index['log_cases'] == 29
         and type(index['actual_inverse_calls']) is int and index['actual_inverse_calls'] == 9,
         'index_contract')
    need(type(index['cases']) is list and len(index['cases']) == 29
         and [v['case_id'] for v in index['cases']] == [c['id'] for c in cases], 'exact_case_order')
    wanted, total, inverse_count, results = {'index.json'}, 0, 0, []

    def artifact(desc, name):
        nonlocal total
        need(type(desc) is dict and set(desc) == {'file', 'bytes', 'sha256'}
             and desc['file'] == name and re.fullmatch(r'[A-Za-z0-9_.-]{1,120}', name)
             and name not in wanted and type(desc['bytes']) is int
             and 0 <= desc['bytes'] <= 4*1024*1024
             and type(desc['sha256']) is str
             and re.fullmatch(r'[a-f0-9]{64}', desc['sha256']), 'artifact_descriptor')
        raw = read(emitted/name, workspace, 4*1024*1024)
        need(len(raw) == desc['bytes'] and audit.digest(raw) == desc['sha256'], 'artifact_pin')
        wanted.add(name)
        total += len(raw)
        need(total <= 16*1024*1024 and len(wanted) <= 128, 'aggregate_cap')
        return raw

    for case, item in zip(cases, index['cases']):
        ident = case['id']
        need(re.fullmatch(r'[A-Za-z0-9_-]+', ident), 'case_name')
        converted = case['expected']['status'] == 'converted'
        keys = {'case_id', 'from', 'to', 'allow_metadata_loss', 'source_fixture',
                'source_sha256', 'source_bytes', 'default_report', 'compact_report', 'status'}
        keys |= {'payload', 'inverse_report', 'inverse_payload'} if converted else {'reason'}
        need(set(item) == keys and item['status'] == case['expected']['status'], 'exact_case_shape')
        source = read(args.corpus.parent/case['input'], workspace, 20*1024*1024)
        need(type(item['source_bytes']) is int and item['source_bytes'] == len(source)
             and item['source_fixture'] == case['input']
             and item['source_sha256'] == audit.digest(source) == case['input_sha256']
             and item['from'] == case['from'] and item['to'] == case['to']
             and item['allow_metadata_loss'] is case['allow_metadata_loss'], 'source_case_binding')
        if not converted:
            need(item['reason'] == case['expected']['reason'], 'manual_refusal_reason')
        plain = artifact(item['default_report'], ident+'.default.json')
        packed = artifact(item['compact_report'], ident+'.compact.json')
        left, le = audit.decode_report(plain, args.codec_sha)
        right, re_ = audit.decode_report(packed, args.codec_sha, False)
        need(le['stored_schema'] == 1 and re_['stored_schema'] == 2
             and audit.typed_equal(left, right), 'typed_entire_report_parity')
        if converted:
            artifact(item['payload'], ident+'.payload')
            artifact(item['inverse_report'], ident+'.inverse.json')
            artifact(item['inverse_payload'], ident+'.inverse.payload')
            inverse_count += 1
        for label in ('default', 'compact'):
            argv = [str(args.auditor), str(emitted/item[label+'_report']['file']),
                    str(output/(ident+'.'+label+'.audit.json')), '--source',
                    str(args.corpus.parent/case['input']), '--oracle', str(args.oracle),
                    '--codec-sha', args.codec_sha, '--source-root', str(workspace),
                    '--from', case['from'], '--to', case['to'], '--corpus', str(args.corpus),
                    '--case-id', ident]
            if label == 'compact':
                argv += ['--require-compact']
            if case['allow_metadata_loss']:
                argv += ['--allow-loss']
            if converted:
                argv += ['--payload', str(emitted/item['payload']['file']),
                         '--inverse-payload', str(emitted/item['inverse_payload']['file']),
                         '--inverse-report', str(emitted/item['inverse_report']['file'])]
            previous = sys.argv
            try:
                sys.argv = argv
                audit.main()
            finally:
                sys.argv = previous
            result = audit.loads(read(Path(argv[2]), workspace, 16*1024))
            need(result['status'] == 'INDEPENDENT_COMPACT_REPORT_DIRECT_SOURCE_PAYLOAD_AUDIT_PASS'
                 and result['frozen_case'] == ident
                 and result['provided_inverse_pair_checked'] is converted, 'case_audit_result')
        results.append({'case_id': ident, 'logical_status': item['status'],
                        'entire_typed_report_parity': True, 'inverse_pair_checked': converted})
    actual = set()
    for node in emitted.iterdir():
        need(len(actual) < 128 and safe(node, workspace).is_file(), 'flat_bounded_emission')
        actual.add(node.name)
    need(actual == wanted and inverse_count == 9, 'exact_emitted_files_and_9_inverse')
    output_files = list(output.iterdir())
    need(len(output_files) == 58 and sum(f.stat().st_size for f in output_files) <= 900*1024,
         'output_bound')
    proof = {'status': 'INDEPENDENT_FROZEN_COMPACT_CORPUS_AUDIT_PASS', 'cases': results,
             'case_count': 29, 'report_audits': 58, 'actual_inverse_pairs_checked': 9,
             'emitted_files': len(wanted), 'emitted_bytes_without_index': total,
             'corpus_sha256': CORPUS_SHA, 'auditor_sha256': AUDIT_SHA,
             'native_invocation_verified': False,
             'limits': ['Saved artifacts only; emitter native invocation and fullEOF are separate gates.',
                        'Inverse function calls are not independent CLI process invocations.']}
    with (output/'audit.json').open('x', encoding='utf-8') as stream:
        json.dump(proof, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
