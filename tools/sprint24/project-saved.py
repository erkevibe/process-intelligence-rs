"""Publish an explicit saved-evidence selection; no product, DB or network calls.

Only literal user-home prefixes are replaced. Original stream descriptors keep
their original digests; manifest rows record both representations separately.
The private selection/configuration and private originals are never published.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import time


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def read_bounded(path, cap):
    with path.open('rb') as stream:
        raw = stream.read(cap + 1)
    need(len(raw) <= cap, 'read_bound')
    return raw


def bounded(root, relative):
    name = PurePosixPath(relative)
    need(isinstance(relative, str) and name.as_posix() == relative and
         not name.is_absolute() and bool(name.parts) and
         all(p not in ('.', '..') for p in name.parts) and
         '\\' not in relative and ':' not in relative, 'relative_path')
    current = root
    for part in name.parts:
        current = current / part
        if current.exists() or current.is_symlink():
            stat = current.lstat()
            need(not current.is_symlink() and not getattr(stat, 'st_file_attributes', 0) & 1024,
                 'reparse_descendant')
    return current


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--config-sha', required=True)
    args = parser.parse_args()
    raw = read_bounded(args.config, 1024 * 1024)
    need(sha(raw).upper() == args.config_sha, 'config_identity')
    config = json.loads(raw)
    root = Path.cwd().resolve(strict=True)
    out = bounded(root, config['output'])
    need(out.is_dir() and not any(out.iterdir()), 'fresh_output')
    need(0 < len(config['files']) <= 1500, 'selection_count')
    # Byte replacement preserves every number lexeme, including FILETIME values.
    home = str(Path.home())
    prefixes = sorted({home, home.replace('\\', '/'),
                       home.replace('\\', '\\\\')}, key=len, reverse=True)
    forbidden = [s.encode() for s in config.get('private_values', []) if len(s) >= 12]
    start = time.monotonic()
    files, destinations, total = [], set(), 0
    for row in config['files']:
        need(time.monotonic() - start < 90, 'projection_deadline')
        source = bounded(root, row['source'])
        target = bounded(out, row['path'])
        need(row['path'] not in destinations and row['path'] != 'manifest.json', 'unique_target')
        destinations.add(row['path'])
        need(source.is_file() and source.stat().st_size <= 4 * 1024 * 1024, 'source_bound')
        original = read_bounded(source, 4 * 1024 * 1024)
        need(len(original) == row['bytes'] and sha(original).upper() == row['sha256'], 'source_identity')
        need(not any(secret in original for secret in forbidden), 'private_value_in_selection')
        text = original.decode('utf-8', errors='strict')
        projected = text
        for prefix in prefixes:
            projected = projected.replace(prefix, 'userprofile:/')
        need(not re.search(r'(?i)(?<![a-z0-9])(?:[a-z]:[\\/]|/(?:Users|home)/)', projected), 'unhandled_absolute_path')
        need(not re.search(r'(?i)(?<![a-z0-9+.-])(?:file:/|postgres(?:ql)?://)', projected) and
             not re.search(r'(?m)(?:^|")(?:/{2,}|\\{2,})[A-Za-z0-9]', projected),
             'unhandled_uri_or_unc')
        data = projected.encode('utf-8')
        total += len(data)
        need(total <= 16 * 1024 * 1024, 'total_bound')
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        files.append({'path': row['path'], 'bytes': len(data), 'sha256': sha(data),
                      'original_bytes': len(original), 'original_sha256': sha(original),
                      'projection': 'literal_user_home_prefix_only' if data != original else 'byte_exact'})
    manifest = {'schema_version': 1, 'file_count': len(files), 'total_bytes': total,
                'files': files, 'scope': 'Saved finite observations, not fresh execution. Native capture hashes remain original; public path projections have separate identities.',
                'omissions': ['private directories, passwords, session cookies, runtime configurations and environment values',
                              'failed-attempt raw captures retained privately; only scoped failure reviews selected']}
    with (out / 'manifest.json').open('xb') as stream:
        stream.write(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2).encode())
        stream.flush()
        os.fsync(stream.fileno())
    print(json.dumps({'status': 'SAVED_SELECTION_PROJECTED_NOT_PRODUCT_EXECUTION',
                      'files': len(files), 'bytes': total,
                      'changed_path_representations': sum(r['projection'] != 'byte_exact' for r in files)}))


if __name__ == '__main__':
    main()
