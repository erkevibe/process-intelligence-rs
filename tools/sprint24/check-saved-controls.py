"""Finite coherent saved-evidence counterfactuals, private copies only.
Root sole execution: no concurrent resource scanner during fixture mutation.
No subprocess, network, DB or product calls. Same-process saved checker only.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import sys
import time

CHECKER_SHA = 'AEB9589D29AB76C33D1CDC38164E259AFCBC244972B71C2C98C7E92599A6737D'
START = time.monotonic()

def need(ok, reason):
    if not ok:
        raise ValueError(reason)

def clock():
    need(time.monotonic() - START <= 90, 'control_deadline')

def sha(raw):
    return hashlib.sha256(raw).hexdigest().upper()

def safe(root, path):
    path = Path(os.path.abspath(path))
    need(path.is_relative_to(root), 'outside_workspace')
    current = root
    for part in ('', *path.relative_to(root).parts):
        current = current if not part else current / part
        if current.exists() or current.is_symlink():
            st = current.lstat()
            need(not current.is_symlink() and not getattr(st, 'st_file_attributes', 0) & 1024, 'reparse')
    return path

def read(path, cap=4 * 1024 * 1024):
    clock()
    with path.open('rb') as stream:
        raw = stream.read(cap + 1)
    need(len(raw) <= cap, 'read_bound')
    return raw

def tree(root):
    result, queue, nodes, total = {}, [root], 0, 0
    while queue:
        parent = queue.pop()
        with os.scandir(parent) as entries:
            for entry in entries:
                clock()
                nodes += 1
                need(nodes <= 2000, 'node_bound')
                path = safe(root, Path(entry.path))
                if entry.is_dir(follow_symlinks=False):
                    queue.append(path)
                else:
                    need(entry.is_file(follow_symlinks=False), 'regular_file')
                    name = path.relative_to(root).as_posix()
                    need(name.casefold() not in {x.casefold() for x in result}, 'casefold_duplicate')
                    raw = read(path)
                    total += len(raw)
                    need(total <= 16 * 1024 * 1024 and len(result) < 700, 'fixture_bound')
                    result[name] = raw
    return result

def write(path, raw, exclusive=False):
    clock()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb' if exclusive else 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())

def rehash_manifest(original, files):
    manifest = json.loads(original)
    rows = []
    for row in manifest['files']:
        if row['path'] not in files:
            continue
        item = dict(row)
        raw = files[row['path']]
        if sha(raw) != item['sha256'].upper() or len(raw) != item['bytes']:
            item.update(bytes=len(raw), sha256=sha(raw).lower(), original_bytes=len(raw),
                        original_sha256=sha(raw).lower(), projection='byte_exact')
        rows.append(item)
    manifest.update(files=rows, file_count=len(rows), total_bytes=sum(r['bytes'] for r in rows))
    return (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--checker', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--fixture', required=True, type=Path)
    parser.add_argument('--proof', required=True, type=Path)
    args = parser.parse_args()
    workspace = Path(os.path.abspath(Path.cwd()))
    checker, source, fixture, proof = [safe(workspace, x) for x in (args.checker, args.evidence, args.fixture, args.proof)]
    need(checker == workspace / 'tools/sprint24/check-saved.py', 'exact_checker_path')
    need(source == workspace / 'evidence/sprint24/saved', 'exact_saved_source')
    need(fixture.is_relative_to(workspace / '.local/sprint21/root/sprint24') and fixture.is_dir() and
         not any(fixture.iterdir()) and proof.is_relative_to(workspace / '.local/sprint21/root/sprint24') and
         proof.parent.is_dir() and not proof.exists() and not proof.is_relative_to(fixture) and
         not source.is_relative_to(fixture) and not fixture.is_relative_to(source), 'fresh_private_fixture')
    checker_raw = read(checker, 65536)
    need(sha(checker_raw) == CHECKER_SHA, 'checker_pin')
    originals = tree(source)
    need(len(originals) == 568 and 'manifest.json' in originals, 'exact_saved_inventory')
    for name, raw in originals.items():
        write(safe(workspace, fixture / PurePosixPath(name)), raw, True)
    module = {'__name__': 'finite_saved_checker', '__file__': str(checker)}
    exec(compile(checker_raw, str(checker), 'exec'), module)

    def run(expected=None):
        clock()
        previous = sys.argv
        capture = io.StringIO()
        sys.argv = [str(checker), str(fixture)]
        try:
            try:
                with contextlib.redirect_stdout(capture):
                    module['main']()
            except ValueError as error:
                need(expected is not None and str(error) == expected, 'specific_expected_rejection')
                need(not capture.getvalue().strip(), 'negative_no_acceptance_output')
                return {'expected': expected, 'actual': str(error), 'accepted': False}
            need(expected is None, 'bad_candidate_accepted')
            raw = capture.getvalue()
            need(len(raw.encode()) <= 65536, 'checker_output_bound')
            report = json.loads(raw)
            need(report['status'] == 'SAVED_SCOPED_CONSISTENCY_PASS_NOT_FRESH_EXECUTION', 'positive_status')
            return {'accepted': True, 'output_sha256': sha(raw.encode())}
        finally:
            sys.argv = previous

    positive = run()
    need(tree(fixture) == originals, 'positive_changed_fixture')
    trials = []
    target = 'capacity/session/postgres.process.json'
    for name, reason in [('missing_capacity_pg', 'capacity_native_inventory'),
                         ('positive_exit137', 'capacity_native_exit'),
                         ('inner_eof_false', 'inner_capture_flags')]:
        files = dict(originals)
        if name == 'missing_capacity_pg':
            changed = target
            del files[target]
            safe(workspace, fixture / target).unlink()
        else:
            changed = 'capacity/session/app10k.process.json'
            descriptor = json.loads(originals[changed])
            descriptor['native_exit' if name == 'positive_exit137' else 'stdout_eof'] = 137 if name == 'positive_exit137' else False
            files[changed] = (json.dumps(descriptor, ensure_ascii=False, indent=2) + '\n').encode()
            write(safe(workspace, fixture / changed), files[changed])
        mutated_manifest = rehash_manifest(originals['manifest.json'], files)
        write(fixture / 'manifest.json', mutated_manifest)
        try:
            result = run(reason)
            result.update(control=name, changed_path=changed, coherent_manifest_sha256=sha(mutated_manifest))
            trials.append(result)
        finally:
            write(safe(workspace, fixture / changed), originals[changed])
            write(fixture / 'manifest.json', originals['manifest.json'])
        need(tree(fixture) == originals, 'restore_not_exact')
    need(tree(source) == originals, 'original_saved_source_changed')
    output = {'status': 'ACTUAL_ONE_POSITIVE_THREE_SPECIFIC_SAVED_CONTROLS', 'checker_sha256': CHECKER_SHA,
              'source_files': len(originals), 'source_bytes': sum(map(len, originals.values())),
              'positive': positive, 'negative': trials, 'original_unchanged': True, 'fixture_restored_exact': True,
              'limits': 'Coherent private counterfactuals of saved consistency checker only; no product/DB/native producer or semantic rerun. No concurrent resource scanner during mutations.'}
    write(proof, (json.dumps(output, ensure_ascii=False, indent=2) + '\n').encode(), True)
    print(json.dumps({'status': output['status'], 'negative_count': len(trials)}))

if __name__ == '__main__':
    main()
