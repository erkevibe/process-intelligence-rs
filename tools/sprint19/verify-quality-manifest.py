"""Check the complete bounded public artifact set and exact original bytes."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


def verify(directory):
    manifest = directory / 'manifest.json'
    if not manifest.is_file() or manifest.is_symlink() or manifest.stat().st_size > 2 * 1024 * 1024:
        raise ValueError('manifest_type_or_size')
    raw = manifest.read_bytes()
    data = json.loads(raw)
    if not data['manifest_excludes_itself'] or not 0 < len(data['files']) <= 2000:
        raise ValueError('manifest_bounds')
    expected, total = {'manifest.json'}, 0
    for row in data['files']:
        relative = PurePosixPath(row['path'])
        if (not isinstance(row['path'], str) or not row['path'] or relative.is_absolute()
                or relative.as_posix() != row['path'] or '..' in relative.parts
                or ':' in row['path'] or '\\' in row['path'] or row['path'] in expected):
            raise ValueError('unique_relative_member_required')
        expected.add(row['path'])
        path = directory.joinpath(*relative.parts)
        if (not path.is_file() or path.is_symlink() or type(row['bytes']) is not int
                or not 0 <= row['bytes'] <= 32 * 1024 * 1024 or path.stat().st_size != row['bytes']):
            raise ValueError('member_type_or_size')
        value = path.read_bytes()
        if len(value) != row['bytes'] or hashlib.sha256(value).hexdigest() != row['sha256']:
            raise ValueError('member_hash_or_size')
        total += len(value)
        if total > 128 * 1024 * 1024:
            raise ValueError('total_byte_limit')
    actual = set()
    for path in directory.rglob('*'):
        if path.is_symlink():
            raise ValueError('symlink_member')
        if path.is_file():
            actual.add(path.relative_to(directory).as_posix())
    if actual != expected or data['logical_bytes'] != total:
        raise ValueError('complete_file_set_or_byte_sum')
    return {'status': 'exact_complete_public_artifact_set_verified', 'files': len(actual),
            'bytes_excluding_manifest': total, 'manifest_sha256': hashlib.sha256(raw).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.directory)))


if __name__ == '__main__':
    main()
