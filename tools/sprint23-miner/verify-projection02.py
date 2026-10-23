"""Independent original-to-public evidence comparison; data only, no engines."""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import time

WORKSPACE = Path(__file__).absolute().parents[2]
PROFILE = Path.home()
ABS = re.compile(r'(?i)(?<![a-z0-9])(?:file:/+)?[a-z]:[\\/]|/(?:Users|home)/')
SCIENCE = {'input_xlog_before', 'input_xlog_after', 'graph', 'exception', 'events', 'attributes', 'traces'}
PROPERTIES = {'user.home', 'java.io.tmpdir', 'java.util.prefs.userRoot', 'java.util.prefs.systemRoot', 'logback.configurationFile'}


class Number(str):
    pass


def need(value, reason):
    if not value:
        raise ValueError(reason)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def parse(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            need(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    return json.loads(raw.decode('utf-8'), object_pairs_hook=pairs, parse_int=Number, parse_float=Number,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))


def no_reparse(path):
    info = path.lstat()
    need(not path.is_symlink() and not getattr(info, 'st_file_attributes', 0) & 1024, 'reparse path')
    return info


def read(path, cap=32 * 1024 * 1024):
    need(no_reparse(path).st_size <= cap and path.is_file(), 'regular bounded file')
    with path.open('rb') as stream:
        raw = stream.read(cap + 1)
    need(len(raw) <= cap, 'file grew')
    return raw


def inventory(root, deadline):
    # Bind the exact workspace, while rejecting every reparse node below it.
    root = Path(os.path.abspath(root))
    need(root.is_relative_to(WORKSPACE), 'outside workspace')
    relative = root.relative_to(WORKSPACE)
    parent = root
    while True:
        no_reparse(parent)
        if parent == WORKSPACE:
            break
        parent = parent.parent
    need(root.resolve(strict=True) == WORKSPACE.resolve(strict=True) / relative,
         'resolved workspace mismatch')
    result, pending, count, total = {}, [root], 0, 0
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as listing:
            for entry in listing:
                count += 1
                need(count <= 20000 and time.monotonic() < deadline, 'enumeration bound')
                path = Path(entry.path); no_reparse(path)
                if path.is_dir():
                    pending.append(path)
                else:
                    raw = read(path); total += len(raw)
                    need(total <= 512 * 1024 * 1024, 'tree byte cap')
                    result[path.relative_to(root).as_posix()] = (sha(raw), len(raw))
    return result


def name(value):
    need(isinstance(value, str) and not isinstance(value, Number), 'path string')
    parts = PurePosixPath(value)
    need(value == parts.as_posix() and parts.parts and not parts.is_absolute() and
         all(p not in ('.', '..') for p in parts.parts) and '\\' not in value and ':' not in value, 'relative path')
    return value


def selected(value):
    p = PurePosixPath(value); parts = p.parts
    if parts[0] not in {'conversions', 'conversion-boundaries', 'miner-performance', 'conversion-audit', 'miner-audit'}:
        return False
    if p.name.startswith('checkpoint-') or p.suffix == '.args':
        return False
    if parts[0] == 'conversion-audit':
        return p.name == 'independent-audit.json'
    if parts[0] == 'miner-audit':
        return p.name == 'independent-audit.json' or len(parts) > 1 and parts[1] == 'independent-audit-semantics'
    return True


def opaque_scientific(value):
    parts = PurePosixPath(value).parts
    if len(parts) >= 3 and parts[0] in {'conversions', 'conversion-boundaries'} and parts[1] == 'inputs':
        return True
    return (len(parts) == 5 and parts[0] == 'conversions' and parts[1] == 'cases' and
            parts[3] in {'forward', 'inverse'} and parts[4] == 'payload.json' or
            len(parts) == 4 and parts[0] == 'conversion-boundaries' and parts[1] == 'cases' and parts[3] == 'payload.json')


def compare_opaque(row, original, published):
    need(opaque_scientific(row['source_path']) and row.get('representation') == 'opaque_scientific_bytes', 'opaque path/representation')
    need(original == published and row['transformations'] == [], 'opaque scientific bytes must remain exact')


def alias(value):
    for base, label in ((WORKSPACE, 'workspace:/'), (PROFILE, 'userprofile:/')):
        for prefix in (str(base), base.as_posix(), 'file:/' + base.as_posix(), 'file:///' + base.as_posix()):
            if value[:len(prefix)].casefold() == prefix.casefold():
                suffix = value[len(prefix):]
                need(not suffix or suffix[0] in '/\\', 'alias prefix boundary')
                return label + suffix.lstrip('/\\').replace('\\', '/')
    raise ValueError('unknown path prefix')


def numeric_digest(obj):
    tokens = []
    def visit(value):
        if isinstance(value, Number):
            tokens.append(str(value))
        elif isinstance(value, list):
            for item in value: visit(item)
        elif isinstance(value, dict):
            for key, item in value.items():
                if key == 'bytes' and {'file', 'sha256', 'bytes'} <= value.keys():
                    continue
                visit(item)
    visit(obj)
    return sha('\n'.join(tokens).encode('ascii'))


def verify(source, published):
    deadline = time.monotonic() + 180
    originals = inventory(source, deadline); actual = inventory(published, deadline)
    manifest = parse(read(published / 'public-projection.json'))
    need(manifest['schema_version'] == '1' and manifest['status'] == 'EXPLICIT_PATH_ONLY_PUBLIC_PROJECTION', 'map schema')
    rows, covered, omissions = {}, set(), set()
    for row in manifest['files']:
        path, origin = name(row['path']), name(row['source_path'])
        need(path not in rows and origin in originals and selected(origin), 'included file selection')
        need(originals[origin] == (row['original_sha256'].lower(), int(row['original_bytes'])), 'actual original identity')
        need(actual.get(path) == (row['published_sha256'].lower(), int(row['published_bytes'])), 'actual published identity')
        preserved = row['preserved_original_capture']
        if row.get('representation') == 'opaque_scientific_bytes':
            need(opaque_scientific(origin) and not preserved, 'opaque representation confined to scientific bytes')
        if preserved:
            expected = origin.rsplit('.', 1)[0] + '.raw.' + origin.rsplit('.', 1)[1]
            need(path == expected and origin.endswith(('/capture/benchmark.stdout', '/capture/benchmark.stderr')), 'only legal raw sidecar')
            need(actual[path] == originals[origin], 'raw sidecar bytes')
        else:
            need(path == origin and origin not in covered, 'primary publication mapping')
            covered.add(origin)
        rows[path] = row
    for row in manifest['omissions']:
        path = name(row['path'])
        need(path not in omissions and path in originals and not selected(path), 'omission must be ancillary')
        need(originals[path] == (row['sha256'].lower(), int(row['bytes'])), 'omitted original identity')
        omissions.add(path)
    need(covered | omissions == set(originals) and not covered & omissions, 'complete original coverage')
    need(set(actual) - set(rows) - {'public-projection.json'} <= {'manifest.json', 'README.md'}, 'unlisted publication file')
    lookup = {}
    for path, row in rows.items():
        if row['preserved_original_capture']: continue
        key = (PurePosixPath(row['source_path']).name, row['original_sha256'].lower(), int(row['original_bytes']))
        target = (row['published_sha256'].lower(), int(row['published_bytes']))
        need(key not in lookup or lookup[key] == target, 'ambiguous artifact identity')
        lookup[key] = target
    changed, digests, raw_sets = [], {}, set()

    def compare(before, after, pointer, file):
        if isinstance(before, dict):
            need(isinstance(after, dict) and list(before) == list(after), 'JSON fields/order')
            replacements = {}
            if {'file', 'sha256', 'bytes'} <= before.keys():
                key = (before['file'], before['sha256'].lower(), int(before['bytes']))
                if key in lookup and lookup[key] != (before['sha256'].lower(), int(before['bytes'])):
                    replacements = {'sha256': lookup[key][0], 'bytes': Number(str(lookup[key][1]))}
            for key in before:
                expected = replacements.get(key, before[key])
                if file == 'miner-performance/index.json' and not pointer and key in ('environment_sha256', 'hardware_sha256'):
                    sibling = 'environment_path' if key == 'environment_sha256' else 'hardware_path'
                    rebound = actual['miner-performance/' + before[sibling]][0]
                    if before[key].lower() != rebound:
                        expected = rebound
                compare(expected, after[key], pointer + (key,), file)
        elif isinstance(before, list):
            need(isinstance(after, list) and len(before) == len(after), 'array order/length')
            for i, value in enumerate(before): compare(value, after[i], pointer + (str(i),), file)
        elif isinstance(before, Number):
            need(isinstance(after, Number) and before == after, 'scientific numeric lexeme')
        elif isinstance(before, str) and ABS.search(before):
            need(not SCIENCE.intersection(pointer), 'scientific path string')
            key = pointer[-1] if pointer else ''
            if 'jvm_arguments' in pointer:
                need(before.startswith('-D') and '=' in before, 'JVM path argument')
                prop, value = before[2:].split('=', 1)
                need(prop in PROPERTIES, 'JVM path property')
                expected = '-D' + prop + '=' + alias(value)
            else:
                need(key in {'program', 'classes', 'origin_path', 'code_source'} or
                     key == 'path' and 'java_sources' in pointer or
                     key == 'file' and 'native_counter_calibrations' in pointer, 'undeclared path field')
                expected = alias(before)
            need(after == expected, 'exact reconstructed path alias')
        else:
            need(type(before) is type(after) and before == after, 'scientific scalar value')

    for path, row in rows.items():
        need(time.monotonic() < deadline, 'comparison deadline')
        old = read(source / row['source_path']); new = read(published / path)
        if row['preserved_original_capture']:
            need(old == new, 'exact original raw capture')
            if path.endswith('.raw.stdout'): raw_sets.add(path.rsplit('/capture/', 1)[0])
        elif opaque_scientific(row['source_path']):
            compare_opaque(row, old, new)
        elif path.endswith('.json'):
            need(row.get('representation') != 'opaque_scientific_bytes', 'metadata cannot use opaque representation')
            before, after = parse(old), parse(new)
            compare(before, after, (), path)
            old_numbers, new_numbers = numeric_digest(before), numeric_digest(after)
            need(old_numbers == new_numbers == row['scientific_numeric_lexeme_sha256'], 'numeric token conservation')
            digests[path] = old_numbers
        elif path.endswith('/capture/benchmark.stdout'):
            left, right = old.splitlines(keepends=True), new.splitlines(keepends=True)
            need(len(left) == len(right), 'console line count')
            for a, b in zip(left, right):
                if a.startswith(b'S20_PROTOCOL ') and parse(a[13:]).get('phase') == 'TERMINAL_READY':
                    x, y = parse(a[13:]), parse(b[13:])
                    need(list(x) == list(y), 'protocol fields')
                    for key in x:
                        if key in {'summary', 'ledger', 'terminal_ready'}:
                            compare(x[key], y[key], (), path)
                        else:
                            need(x[key] == y[key] and type(x[key]) is type(y[key]), 'protocol identity or scientific value')
                    def skeleton(line):
                        for key in ('summary', 'ledger', 'terminal_ready'):
                            line, count = re.subn(rb'("' + key.encode() + rb'"\s*:\s*)\{[^{}]*\}', lambda m: m[1] + b'{DESCRIPTOR}', line)
                            need(count == 1, 'descriptor span')
                        return line
                    need(skeleton(a) == skeleton(b), 'non-descriptor console bytes')
                else:
                    need(a == b, 'raw BOOT/nonprotocol console bytes')
        else:
            need(old == new, 'scientific payload or ordinary stream bytes')
        if old != new: changed.append(path)
    need(raw_sets == {'miner-performance/cold-r1-scale-linear'}, 'exact_single_scale_original_raw_capture_set')
    return {'status': 'INDEPENDENT_ORIGINAL_TO_PUBLIC_PROJECTION_PASS', 'original_files': len(originals),
            'included_primary_files': len(covered), 'omitted_ancillary_files': len(omissions), 'published_mapped_files': len(rows),
            'original_raw_capture_sets': len(raw_sets), 'changed_paths': changed, 'numeric_lexeme_digests': digests,
            'all_scientific_fields_order_and_payload_bytes_conserved': True, 'no_engine_execution': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('source', 'published', 'output'): parser.add_argument('--' + key, type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.source, args.published)
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2); stream.write('\n')


if __name__ == '__main__':
    main()
