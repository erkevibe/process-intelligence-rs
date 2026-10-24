"""Verify the complete portable Sprint20 evidence inventory, including raw bytes."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def verify(root):
    def no_reparse(path):
        stat = path.lstat()
        if path.is_symlink() or getattr(stat, 'st_file_attributes', 0) & 1024:
            raise ValueError('reparse evidence')
        return stat

    no_reparse(root)
    root = root.resolve(strict=True)
    manifest = root / 'manifest.json'
    if no_reparse(manifest).st_size > 4 * 1024 * 1024:
        raise ValueError('manifest size')
    value = json.loads(manifest.read_text(encoding='utf-8'), object_pairs_hook=pairs)
    if (type(value['schema_version']) is not int or value['schema_version'] != 1 or
            type(value['file_count']) is not int or type(value['total_bytes']) is not int or
            not isinstance(value['files'], list) or len(value['files']) > 10000):
        raise ValueError('manifest schema')
    rows = {}
    for row in value['files']:
        name = row['path']
        path = PurePosixPath(name)
        if (not isinstance(name, str) or '\\' in name or ':' in name or
                path.is_absolute() or not path.parts or
                any(part in ('.', '..') for part in path.parts) or
                path.as_posix() != name or name == 'manifest.json' or name in rows):
            raise ValueError('manifest path')
        if type(row['bytes']) is not int or not 0 <= row['bytes'] <= 64 * 1024 * 1024:
            raise ValueError('file byte bound')
        rows[name] = row
    actual = {}
    visited = 0
    for path in root.rglob('*'):
        visited += 1
        if visited > 20000:
            raise ValueError('evidence enumeration bound')
        no_reparse(path)
        if path.is_file() and path != manifest:
            if len(actual) >= 10000:
                raise ValueError('evidence file count bound')
            actual[path.relative_to(root).as_posix()] = path
    if set(actual) != set(rows) or len(actual) > 10000:
        raise ValueError('complete evidence file set')
    total = 0
    for name, path in actual.items():
        row = rows[name]
        if path.stat().st_size != row['bytes']:
            raise ValueError('evidence length: ' + name)
        total += row['bytes']
        if total > 128 * 1024 * 1024:
            raise ValueError('total evidence bound')
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != row['sha256'].lower():
            raise ValueError('evidence SHA256: ' + name)
    if value['file_count'] != len(actual) or value['total_bytes'] != total:
        raise ValueError('inventory totals')
    return {'status': 'COMPLETE_EVIDENCE_BYTES_VERIFIED', 'files': len(actual), 'bytes': total}


if __name__ == '__main__':
    print(json.dumps(verify(Path(sys.argv[1]))))
