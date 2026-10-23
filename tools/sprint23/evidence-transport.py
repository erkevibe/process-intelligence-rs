"""Explicit-manifest lossless S23 transport; no redaction or descriptor rewriting.

Pack requires separately reviewed selection SHA. Compact report privacy is
screened after independent bounded decoding; this is not a general privacy proof.
Unpack/verify bind rows to a supplied selection SHA label, not original selection
entries. Public authenticity requires an independently pinned Git/frozen transport
manifest; no signature or original-selection revalidation is claimed. Nested SQL
report strings require separate privacy review. Raw33MiB SQL exceeds this32MiB cap.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import time
import zlib

TOTAL, RAW, STORED, COUNT = 64*1024*1024, 32*1024*1024, 4*1024*1024, 1000
MANIFEST = 'transport-manifest.json'
AUDITOR_SHA = '048A57750159B49D20E3CCABB02ACB1A7C4320A1C676DAB1B91291CF7114B802'
END = 0


def need(ok, why):
    if not ok:
        raise ValueError(why)
    if END and time.monotonic() >= END:
        raise ValueError('transport_deadline')


def sha(raw):
    return hashlib.sha256(raw).hexdigest().upper()


def pairs(items):
    result = {}
    for k, v in items:
        need(k not in result, 'duplicate_json_key')
        result[k] = v
    return result


def parse(raw):
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: need(False, 'nonfinite_json'))


def rel(name):
    need(type(name) is str and 0 < len(name) <= 240
         and not any(c in name for c in ('\\', ':', '\0')), 'relative_name')
    for p in name.split('/'):
        need(p and p not in ('.', '..') and not p.endswith(('.', ' '))
             and not re.fullmatch(r'(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', p),
             'unambiguous_component')
    return name


def names(values):
    folded = [rel(v).casefold() for v in values]
    need(len(set(folded)) == len(folded), 'casefold_collision')
    allnames = set(folded)
    for value in folded:
        parts = value.split('/')
        need(all('/'.join(parts[:i]) not in allnames for i in range(1, len(parts))),
             'file_directory_collision')


def chain(path, workspace):
    need('..' not in path.parts and path.is_relative_to(workspace), 'workspace_boundary')
    current = workspace
    for part in (None, *path.relative_to(workspace).parts):
        if part is not None:
            current /= part
        info = current.lstat()
        need(not current.is_symlink() and not getattr(info, 'st_file_attributes', 0) & 1024,
             'reparse_refused')


def read(path, cap, workspace):
    chain(path, workspace)
    need(path.is_file() and path.stat().st_size <= cap, 'file_cap')
    chunks, size = [], 0
    with path.open('rb') as stream:
        while True:
            chunk = stream.read(min(65536, cap-size+1))
            if not chunk:
                break
            size += len(chunk)
            need(size <= cap, 'stream_cap_before_append')
            chunks.append(chunk)
    return b''.join(chunks)


def inventory(root, workspace):
    chain(root, workspace)
    pending, found, nodes = [root], {}, 0
    while pending:
        with os.scandir(pending.pop()) as entries:
            for entry in entries:
                nodes += 1
                need(nodes <= 2000, 'node_cap')
                path = Path(entry.path)
                chain(path, workspace)
                if entry.is_dir(follow_symlinks=False):
                    pending.append(path)
                else:
                    need(entry.is_file(follow_symlinks=False) and len(found) < COUNT+1, 'file_count')
                    found[rel(path.relative_to(root).as_posix())] = path
    names(found)
    return found


def inflate(raw, length):
    decoder, chunks, size = zlib.decompressobj(31), [], 0
    for offset in range(0, len(raw), 65536):
        data = raw[offset:offset+65536]
        while data:
            chunk = decoder.decompress(data, min(65536, length-size+1))
            size += len(chunk)
            need(size <= length, 'gzip_expansion_cap_before_append')
            chunks.append(chunk)
            data = decoder.unconsumed_tail
            if decoder.eof:
                need(not decoder.unused_data and not data and offset+65536 >= len(raw),
                     'gzip_concat_or_trailing')
                break
    need(decoder.eof and size == length and not decoder.unused_data, 'gzip_complete_exact')
    return b''.join(chunks)


def compact_screen(raw, audit):
    if raw.lstrip().startswith(b'{'):
        value = parse(raw)
        if type(value) is dict and type(value.get('schema_version')) is int and value['schema_version'] == 2:
            value, _ = audit.decode_report(raw, allow_legacy=False, require_codec_identity=False)
            def walk(v):
                if type(v) is dict:
                    for k, item in v.items():
                        need(k.casefold() not in {'password', 'authorization', 'cookie', 'access_token',
                                                  'refresh_token', 'database_url'}, 'decoded_secret_field')
                        walk(item)
                elif type(v) is list:
                    for item in v:
                        walk(item)
                elif type(v) is str:
                    need(not re.search(r'(?i)(?:(?<![a-z0-9])[a-z]:[\\/]|\\\\|file:/|postgres(?:ql)?://)', v),
                         'decoded_machine_or_connection_path')
            walk(value)


class BoundedGzipSink:
    def __init__(self):
        self.parts, self.size = [], 0

    def write(self, data):
        need(self.size+len(data) <= STORED, 'compressed_cap_before_append')
        self.parts.append(bytes(data))
        self.size += len(data)
        return len(data)

    def flush(self):
        pass


def main():
    global END
    END = time.monotonic()+90
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=('pack', 'unpack', 'verify'))
    p.add_argument('source', type=Path, help='selection JSON for pack, stored directory otherwise')
    p.add_argument('--output', type=Path)
    p.add_argument('--workspace', type=Path, required=True)
    p.add_argument('--selection-sha', required=True)
    p.add_argument('--auditor', type=Path, required=True)
    args = p.parse_args()
    workspace = args.workspace.absolute()
    need(re.fullmatch('[0-9A-F]{64}', args.selection_sha), 'selection_pin_format')
    need(sha(read(args.auditor.absolute(), 128*1024, workspace)) == AUDITOR_SHA, 'auditor_pin')
    spec = importlib.util.spec_from_file_location('independent_compact_audit', args.auditor)
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    staged, rows, total, stored_total = {}, [], 0, 0
    if args.mode == 'pack':
        selection_raw = read(args.source.absolute(), 1024*1024, workspace)
        need(sha(selection_raw) == args.selection_sha, 'reviewed_selection_pin')
        selection = parse(selection_raw)
        need(type(selection) is dict and set(selection) == {'schema_version', 'entries'}
             and type(selection['schema_version']) is int and selection['schema_version'] == 1
             and type(selection['entries']) is list and len(selection['entries']) <= COUNT, 'selection_schema')
        source_pins = []
        for e in selection['entries']:
            need(type(e) is dict and set(e) == {'source_path', 'logical_path', 'encoding', 'raw_bytes', 'raw_sha256'},
                 'selection_entry_schema')
            name = rel(e['logical_path']); src = workspace/rel(e['source_path'])
            need(type(e['raw_bytes']) is int and 0 <= e['raw_bytes'] <= RAW
                 and type(e['raw_sha256']) is str and re.fullmatch('[0-9A-F]{64}', e['raw_sha256']), 'raw_descriptor')
            raw = read(src, RAW, workspace)
            need(len(raw) == e['raw_bytes'] and sha(raw) == e['raw_sha256'], 'source_pin')
            compact_screen(raw, audit)
            need(e['encoding'] in ('identity', 'gzip'), 'encoding')
            if e['encoding'] == 'gzip':
                sink = BoundedGzipSink()
                with gzip.GzipFile(filename='', mode='wb', fileobj=sink, mtime=0, compresslevel=6) as z:
                    for offset in range(0, len(raw), 65536):
                        z.write(raw[offset:offset+65536])
                payload = b''.join(sink.parts); stored = name+'.gz'
                need(inflate(payload, len(raw)) == raw, 'pack_roundtrip')
            else:
                payload, stored = raw, name
            need(len(payload) <= STORED, 'stored_member_cap')
            total += len(raw); stored_total += len(payload)
            need(total <= TOTAL and stored_total <= TOTAL, 'total_cap')
            rows.append({'logical_path': name, 'stored_path': stored, 'encoding': e['encoding'],
                         'raw_bytes': len(raw), 'raw_sha256': sha(raw),
                         'stored_bytes': len(payload), 'stored_sha256': sha(payload)})
            need(stored not in staged, 'stored_collision')
            staged[stored] = payload
            source_pins.append((src, len(raw), sha(raw)))
        names([r['logical_path'] for r in rows]); names(list(staged)+[MANIFEST])
        for src, length, pin in source_pins:
            raw = read(src, RAW, workspace)
            need(len(raw) == length and sha(raw) == pin, 'source_changed')
        need(read(args.source.absolute(), 1024*1024, workspace) == selection_raw,
             'selection_changed')
        manifest = {'schema_version': 1, 'selection_sha256': args.selection_sha,
                    'raw_bytes': total, 'stored_bytes': stored_total, 'entries': rows}
        staged[MANIFEST] = (json.dumps(manifest, indent=2)+'\n').encode()
        need(len(staged[MANIFEST]) <= 1024*1024, 'manifest_cap')
    else:
        found = inventory(args.source.absolute(), workspace)
        manifest_raw = read(found[MANIFEST], 1024*1024, workspace)
        manifest = parse(manifest_raw)
        need(type(manifest) is dict and set(manifest) == {'schema_version', 'selection_sha256', 'raw_bytes', 'stored_bytes', 'entries'}
             and type(manifest['schema_version']) is int and manifest['schema_version'] == 1
             and manifest['selection_sha256'] == args.selection_sha
             and type(manifest['entries']) is list and len(manifest['entries']) <= COUNT, 'transport_schema')
        rows = manifest['entries']
        for e in rows:
            need(type(e) is dict and set(e) == {'logical_path', 'stored_path', 'encoding', 'raw_bytes', 'raw_sha256', 'stored_bytes', 'stored_sha256'}, 'transport_entry')
            name, stored = rel(e['logical_path']), rel(e['stored_path'])
            need(all(type(e[k]) is int and 0 <= e[k] <= cap for k, cap in [('raw_bytes', RAW), ('stored_bytes', STORED)])
                 and all(type(e[k]) is str and re.fullmatch('[0-9A-F]{64}', e[k]) for k in ('raw_sha256', 'stored_sha256')), 'typed_bounds_hashes')
            total += e['raw_bytes']; stored_total += e['stored_bytes']
            need(total <= TOTAL and stored_total <= TOTAL, 'total_cap')
            payload = read(found[stored], STORED, workspace)
            need(len(payload) == e['stored_bytes'] and sha(payload) == e['stored_sha256'], 'stored_pin')
            if e['encoding'] == 'gzip':
                need(stored == name+'.gz', 'gzip_name')
                raw = inflate(payload, e['raw_bytes'])
            else:
                need(e['encoding'] == 'identity' and stored == name, 'identity_name')
                raw = payload
            need(len(raw) == e['raw_bytes'] and sha(raw) == e['raw_sha256'], 'raw_pin')
            compact_screen(raw, audit)
            staged[name] = raw
        names([e['logical_path'] for e in rows]); names([e['stored_path'] for e in rows]+[MANIFEST])
        need(set(found) == {e['stored_path'] for e in rows}|{MANIFEST}, 'exact_package_set')
        need(type(manifest['raw_bytes']) is int and type(manifest['stored_bytes']) is int
             and total == manifest['raw_bytes'] and stored_total == manifest['stored_bytes'], 'exact_totals')
        need(read(found[MANIFEST], 1024*1024, workspace) == manifest_raw, 'manifest_changed')
        for e in rows:
            payload = read(found[e['stored_path']], STORED, workspace)
            need(len(payload) == e['stored_bytes'] and sha(payload) == e['stored_sha256'],
                 'stored_source_changed')
    if args.mode != 'verify':
        need(args.output is not None, 'output_required')
        output = args.output.absolute(); source = args.source.absolute()
        need(not output.exists() and not output.is_relative_to(source)
             and not source.is_relative_to(output), 'fresh_disjoint_output')
        chain(output.parent, workspace); output.mkdir()
        for name, raw in staged.items():
            path = output/rel(name); path.parent.mkdir(parents=True, exist_ok=True)
            chain(path.parent, workspace)
            with path.open('xb') as stream:
                stream.write(raw)
            need(read(path, RAW, workspace) == raw, 'write_verification')
    print(json.dumps({'mode': args.mode, 'files': len(rows), 'raw_bytes': total,
                      'stored_bytes': stored_total, 'all_bytes_verified': True,
                      'native_descriptors_rebound': False,
                      'privacy_scope': 'Top-level compact inner screen only; nested SQL/report strings require separate review.',
                      'trust_limit': 'Selection SHA label is not row authentication; independently pin Git/frozen transport manifest.'}))


if __name__ == '__main__':
    main()
