"""Finite actual-tool transport corruption controls; no subprocess or network."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import time

TOOL_SHA = '3C3CEFD6DAFF815DF01831C6843B0A610A165EDD09654BEC3C7F0FB3B4E6C54D'


def sha(raw):
    return hashlib.sha256(raw).hexdigest().upper()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('tool', type=Path)
    p.add_argument('fixtures', type=Path, help='existing fresh protected private directory')
    p.add_argument('--workspace', type=Path, required=True)
    p.add_argument('--auditor', type=Path, required=True)
    args = p.parse_args(); start = time.monotonic()
    def need(ok, why):
        if not ok:
            raise ValueError(why)
        if time.monotonic()-start > 45:
            raise ValueError('control_deadline')
    workspace = args.workspace.absolute(); root = args.fixtures.absolute()
    need(root.is_relative_to(workspace) and '..' not in root.parts, 'fixture_boundary')
    cursor = workspace
    for part in (None, *root.relative_to(workspace).parts):
        if part is not None:
            cursor /= part
        st = cursor.lstat()
        need(not cursor.is_symlink() and not getattr(st, 'st_file_attributes', 0)&1024, 'no_reparse')
    need(root.is_dir() and not any(root.iterdir()), 'fresh_fixture')
    need(args.tool.stat().st_size <= 64*1024 and sha(args.tool.read_bytes()) == TOOL_SHA, 'tool_pin')
    spec = importlib.util.spec_from_file_location('actual_transport_under_test', args.tool)
    tool = importlib.util.module_from_spec(spec); spec.loader.exec_module(tool)
    raw = ('finite synthetic transport control; кириллица; '+ 'A'*1024).encode()
    source = root/'synthetic.txt'; source.write_bytes(raw)
    selection = {'schema_version': 1, 'entries': [{
        'source_path': source.relative_to(workspace).as_posix(), 'logical_path': 'science/synthetic.txt',
        'encoding': 'gzip', 'raw_bytes': len(raw), 'raw_sha256': sha(raw)}]}
    selection_path = root/'selection.json'
    selection_raw = json.dumps(selection).encode(); selection_path.write_bytes(selection_raw)
    selection_sha = sha(selection_raw)
    def invoke(mode, path, output=None):
        previous = sys.argv
        argv = [str(args.tool), mode, str(path), '--workspace', str(workspace),
                '--selection-sha', selection_sha, '--auditor', str(args.auditor)]
        if output:
            argv += ['--output', str(output)]
        try:
            sys.argv = argv
            tool.main()
        finally:
            sys.argv = previous
        need(True, 'deadline')
    package = root/'positive'; decoded = root/'decoded'
    invoke('pack', selection_path, package)
    invoke('verify', package)
    invoke('unpack', package, decoded)
    need((decoded/'science/synthetic.txt').read_bytes() == raw, 'positive_exact_bytes')
    positive_pins = {f.relative_to(package).as_posix(): sha(f.read_bytes())
                     for f in package.rglob('*') if f.is_file()}
    cases = [('wrong_hash', 'stored_pin'), ('trailing_gzip', 'gzip_concat_or_trailing'),
             ('path_traversal', 'unambiguous_component'), ('extra_file', 'exact_package_set')]
    results = []
    for name, expected in cases:
        target = root/name
        shutil.copytree(package, target)
        manifest_path = target/'transport-manifest.json'
        manifest = json.loads(manifest_path.read_bytes()); entry = manifest['entries'][0]
        if name == 'wrong_hash':
            entry['stored_sha256'] = '0'*64
        elif name == 'trailing_gzip':
            payload_path = target/entry['stored_path']
            payload = payload_path.read_bytes()+b'!'
            payload_path.write_bytes(payload)
            entry['stored_bytes'], entry['stored_sha256'] = len(payload), sha(payload)
            manifest['stored_bytes'] = len(payload)
        elif name == 'path_traversal':
            entry['logical_path'] = '../escape.txt'
        else:
            (target/'not-in-manifest.bin').write_bytes(b'extra')
        manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
        reason = None
        try:
            invoke('verify', target)
        except ValueError as error:
            reason = str(error)
        need(reason == expected, 'specific_rejection_'+name)
        results.append({'case': name, 'rejected': True, 'reason': reason})
    # Bounded known tree only, not a generic filesystem walk.
    total = sum(f.stat().st_size for f in root.rglob('*') if f.is_file())
    need(total <= 128*1024 and not (root/'escape.txt').exists(), 'fixture_output_bound')
    need({f.relative_to(package).as_posix(): sha(f.read_bytes())
          for f in package.rglob('*') if f.is_file()} == positive_pins, 'positive_package_unchanged')
    proof = {'status': 'FINITE_ACTUAL_TRANSPORT_CONTROLS_PASS', 'positive': 'pack/verify/unpack exactbytes',
             'tool_sha256': TOOL_SHA, 'rejections': results, 'fixture_bytes': total,
             'original_package_unchanged': True,
             'limits': ['Synthetic fixture only; actual reviewed public selection and Git manifest pin are separate gates.',
                        'No compact semantic or generic privacy proof from these controls.']}
    with (root/'controls-proof.json').open('x', encoding='utf-8') as stream:
        json.dump(proof, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
