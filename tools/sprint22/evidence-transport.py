"""Lossless, bounded S22 evidence transport. Never rewrite native descriptors."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import time
import zlib

MAX_TOTAL = 64 * 1024 * 1024
MAX_FILE = 32 * 1024 * 1024
MAX_FILES = 1000
POLICY = 'E29223B3CB01729BAB84A1979D80C6F7EAEE1A8CCAF6EE90C4FDAD8DD2EBFB88'
MANIFEST = 'transport-manifest.json'
LARGE = {
    'inputs/CMP10K.xes', 'inputs/CMP90K.xes',
    'inputs/CMP10K.expected-lf.csv', 'inputs/CMP90K.expected-lf.csv',
    'measurement/http-10k/payload.bin', 'measurement/http-10k/report.bin',
    'measurement/session/source10k.stdout', 'measurement/session/source90k.stdout',
}


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def digest(raw):
    return hashlib.sha256(raw).hexdigest().upper()


def relative(value):
    need(type(value) is str and value and not any(c in value for c in ('\\', ':', '\0')), 'relative_name')
    parts = value.split('/')
    need(all(p and p not in ('.', '..') and not p.endswith(('.', ' ')) and re.fullmatch(r'(?i)(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', p) is None for p in parts), 'unambiguous_name')
    need(not PurePosixPath(value).is_absolute(), 'relative_name')
    return value


def pairs(items):
    result = {}
    for key, item in items:
        need(key not in result, 'duplicate_json_key')
        result[key] = item
    return result


def parse(raw):
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite_json')))


def no_reparse(path):
    info = path.lstat()
    need(not path.is_symlink() and not (getattr(info, 'st_file_attributes', 0) & 1024), 'no_reparse')
    return info


def chain(path, workspace):
    need(path.is_relative_to(workspace), 'workspace_boundary')
    no_reparse(workspace)
    cursor = workspace
    for part in path.relative_to(workspace).parts:
        cursor = cursor / part
        no_reparse(cursor)


def files(root, workspace, deadline):
    chain(root, workspace)
    pending = [root]
    result = {}
    nodes = 0
    while pending:
        need(time.monotonic() < deadline, 'transport_deadline')
        parent = pending.pop()
        with os.scandir(parent) as entries:
            for entry in entries:
                nodes += 1
                need(nodes <= 2000, 'transport_node_cap')
                path = Path(entry.path)
                no_reparse(path)
                if entry.is_dir(follow_symlinks=False):
                    pending.append(path)
                else:
                    need(entry.is_file(follow_symlinks=False), 'regular_file')
                    name = relative(path.relative_to(root).as_posix())
                    need(name.casefold() not in {n.casefold() for n in result} and len(result) < MAX_FILES + 1, 'file_inventory_cap_collision')
                    result[name] = path
    return result


def read(path, cap, workspace):
    chain(path, workspace)
    need(path.is_file() and path.stat().st_size <= cap, 'bounded_file')
    with path.open('rb') as stream:
        raw = stream.read(cap + 1)
    need(len(raw) <= cap, 'bounded_read')
    return raw


def projection_check(decoded):
    need('projection-manifest.json' in decoded, 'projection_manifest_required')
    manifest = parse(decoded['projection-manifest.json'])
    expected = {'projection-manifest.json'}
    for item in manifest['entries']:
        name = relative(item['public_path'])
        if item['mode'] == 'omit':
            need(name not in decoded, 'omitted_file_present')
            continue
        need(name not in expected, 'duplicate_projection_name')
        expected.add(name)
        need(name in decoded and len(decoded[name]) == item['public_bytes'] and digest(decoded[name]) == item['public_sha256'].upper(), 'projection_bytes_sha')
    need(set(decoded) == expected, 'exact_projected_fileset')


def inflate(raw, length):
    need(type(length) is int and 0 <= length <= MAX_FILE, 'decoded_size_bound')
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    decoded = decoder.decompress(raw, length + 1)
    need(len(decoded) == length and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail, 'single_complete_gzip_member_no_trailing_bytes')
    return decoded


def tree_names(names):
    folded = [relative(name).casefold() for name in names]
    unique = set(folded)
    need(len(unique) == len(folded), 'casefold_file_collision')
    for name in unique:
        parts = name.split('/')
        need(all('/'.join(parts[:n]) not in unique for n in range(1, len(parts))), 'file_directory_prefix_collision')


def write_tree(output, staged, workspace, deadline):
    tree_names(staged)
    need(not output.exists(), 'fresh_output')
    chain(output.parent, workspace)
    output.mkdir()
    for name, raw in staged.items():
        need(time.monotonic() < deadline, 'transport_deadline')
        path = output / relative(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        chain(path.parent, workspace)
        with path.open('xb') as stream:
            stream.write(raw)
        need(read(path, MAX_FILE, workspace) == raw, 'transport_write_verification')


def transport(mode, source, output, workspace):
    deadline = time.monotonic() + 90
    workspace = Path(os.path.abspath(workspace))
    source = Path(os.path.abspath(source))
    output = Path(os.path.abspath(output))
    need(source != output and not output.is_relative_to(source) and not source.is_relative_to(output), 'separate_trees')
    inventory = files(source, workspace, deadline)
    need(len(inventory) <= MAX_FILES + (mode == 'decode'), 'file_count')
    staged, decoded = {}, {}
    total = stored_total = 0
    if mode == 'encode':
        need(MANIFEST not in inventory and len(inventory) <= MAX_FILES, 'no_existing_transport_manifest')
        rows = []
        stored_names = set()
        for name in sorted(inventory):
            need(time.monotonic() < deadline, 'transport_deadline')
            raw = read(inventory[name], MAX_FILE, workspace)
            total += len(raw)
            need(total <= MAX_TOTAL, 'decoded_total_cap')
            decoded[name] = raw
            compressed = name in LARGE and len(raw) >= 256 * 1024
            encoding = 'gzip' if compressed else 'identity'
            stored = name + '.gz' if compressed else name
            need(stored.casefold() not in stored_names and stored.casefold() != MANIFEST, 'stored_name_collision')
            stored_names.add(stored.casefold())
            payload = gzip.compress(raw, compresslevel=6, mtime=0) if compressed else raw
            need(len(payload) <= MAX_FILE, 'stored_file_cap')
            stored_total += len(payload)
            need(stored_total <= MAX_TOTAL, 'stored_total_cap')
            if compressed:
                need(inflate(payload, len(raw)) == raw, 'encoder_roundtrip')
            staged[stored] = payload
            rows.append({'logical_path': name, 'stored_path': stored, 'encoding': encoding, 'projected_bytes': len(raw), 'projected_sha256': digest(raw), 'stored_bytes': len(payload), 'stored_sha256': digest(payload)})
        projection_check(decoded)
        manifest = {'schema_version': 1, 'projection_policy_sha256': POLICY, 'decoded_bytes': total, 'stored_bytes': stored_total, 'projection_manifest_sha256': digest(decoded['projection-manifest.json']), 'entries': rows, 'native_capture_hash_policy': 'Native descriptors retain original decoded stream hashes; compression hashes are separate transport fields.'}
        encoded_manifest = (json.dumps(manifest, indent=2) + '\n').encode()
        need(len(encoded_manifest) <= 1024 * 1024, 'transport_manifest_cap')
        staged[MANIFEST] = encoded_manifest
    else:
        manifest_raw = read(inventory[MANIFEST], 1024 * 1024, workspace)
        manifest = parse(manifest_raw)
        need(type(manifest) is dict and type(manifest.get('schema_version')) is int and manifest['schema_version'] == 1 and manifest.get('projection_policy_sha256') == POLICY and type(manifest.get('entries')) is list and len(manifest['entries']) <= MAX_FILES, 'transport_schema_policy')
        logical_names, stored_names = set(), set()
        for item in manifest['entries']:
            need(time.monotonic() < deadline, 'transport_deadline')
            need(type(item) is dict and set(item) == {'logical_path', 'stored_path', 'encoding', 'projected_bytes', 'projected_sha256', 'stored_bytes', 'stored_sha256'}, 'entry_schema')
            need(all(type(item[k]) is str and re.fullmatch(r'[0-9A-F]{64}', item[k]) for k in ('projected_sha256', 'stored_sha256')), 'entry_hash_schema')
            name, stored = relative(item['logical_path']), relative(item['stored_path'])
            need(name.casefold() not in logical_names and stored.casefold() not in stored_names and stored.casefold() != MANIFEST, 'logical_stored_collision')
            logical_names.add(name.casefold()); stored_names.add(stored.casefold())
            need(type(item['projected_bytes']) is int and 0 <= item['projected_bytes'] <= MAX_FILE and type(item['stored_bytes']) is int and 0 <= item['stored_bytes'] <= MAX_FILE, 'declared_file_bounds')
            total += item['projected_bytes']; stored_total += item['stored_bytes']
            need(total <= MAX_TOTAL and stored_total <= MAX_TOTAL, 'declared_total_bounds')
            payload = read(inventory[stored], MAX_FILE, workspace)
            need(len(payload) == item['stored_bytes'] and digest(payload) == item['stored_sha256'], 'stored_bytes_sha')
            if item['encoding'] == 'gzip':
                need(name in LARGE and stored == name + '.gz', 'gzip_whitelist')
                raw = inflate(payload, item['projected_bytes'])
            else:
                need(item['encoding'] == 'identity' and stored == name, 'known_encoding_identity_path')
                raw = payload
            need(len(raw) == item['projected_bytes'] and digest(raw) == item['projected_sha256'], 'decoded_bytes_sha')
            decoded[name] = raw
        tree_names(decoded)
        tree_names([e['stored_path'] for e in manifest['entries']] + [MANIFEST])
        need(set(inventory) == {e['stored_path'] for e in manifest['entries']} | {MANIFEST}, 'exact_stored_fileset')
        need(total == manifest['decoded_bytes'] and stored_total == manifest['stored_bytes'] and digest(decoded['projection-manifest.json']) == manifest['projection_manifest_sha256'], 'transport_totals_projection_binding')
        projection_check(decoded)
        staged = decoded
    # Re-read inputs before writing any new output; no source file is modified.
    for name, path in inventory.items():
        need(time.monotonic() < deadline, 'transport_deadline')
        if mode == 'encode':
            need(read(path, MAX_FILE, workspace) == decoded[name], 'source_changed')
        elif name != MANIFEST:
            item = next(row for row in manifest['entries'] if row['stored_path'] == name)
            need(digest(read(path, MAX_FILE, workspace)) == item['stored_sha256'], 'stored_source_changed')
    if mode == 'decode':
        need(read(inventory[MANIFEST], 1024 * 1024, workspace) == manifest_raw, 'transport_manifest_changed')
    write_tree(output, staged, workspace, deadline)
    need(time.monotonic() < deadline, 'transport_deadline')
    return {'mode': mode, 'logical_files': len(decoded), 'decoded_bytes': total, 'stored_bytes_without_manifest': stored_total, 'all_bytes_verified': True, 'native_descriptors_rebound': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['encode', 'decode'])
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--workspace', type=Path, default=Path.cwd())
    args = parser.parse_args()
    print(json.dumps(transport(args.mode, args.source, args.output, args.workspace)))
