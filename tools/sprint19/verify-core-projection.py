"""Verify the complete immutable public Core observation artifact inventory."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


def verify(directory):
    manifest_path = directory / 'projection-manifest.json'
    raw = manifest_path.read_bytes()
    if len(raw) > 4 * 1024 * 1024:
        raise ValueError('bounded_manifest')
    manifest = json.loads(raw)
    profiles = {
        'calendar': 'f363e0952bcc8c153b7e269eba6535787a856a7e8693961fdaeaf6cc77de347e',
        'filter-extended': '87d9c3731c66eedc0bf54fbb7a6652c8b20f507c9a1000f3d0ffeac46acfe5d3',
    }
    if (manifest['schema_version'] != 1
            or manifest['status'] != 'FINITE_NUMERIC_LEXEME_PRESERVING_PUBLIC_FIELD_PROJECTION'
            or manifest['corpus_sha256'] != profiles.get(manifest['profile'])
            or manifest['source_sha256'] != 'f9a548020af768604a9f941d30cfd07c0d419b15d36f6974c854146e5b849d2d'):
        raise ValueError('original_profile_or_transform_identity')
    products = manifest['products']
    if not 1 <= len(products) <= 2000:
        raise ValueError('bounded_product_count')
    expected, total = {'projection-manifest.json'}, 0
    for row in products:
        name = row['path']
        path = PurePosixPath(name)
        if (not isinstance(name, str) or path.is_absolute() or '\\' in name
                or ':' in name or '..' in path.parts or path.as_posix() != name
                or name in expected):
            raise ValueError('unique_relative_product')
        expected.add(name)
        target = directory / name
        if target.is_symlink() or not target.is_file() or target.stat().st_size != row['bytes']:
            raise ValueError('regular_exact_size_product')
        total += row['bytes']
        if total > 128 * 1024 * 1024:
            raise ValueError('bounded_total_bytes')
        if hashlib.sha256(target.read_bytes()).hexdigest() != row['sha256']:
            raise ValueError('product_sha256')
    actual = set()
    for path in directory.rglob('*'):
        if path.is_symlink():
            raise ValueError('no_symlink_members')
        if path.is_file():
            actual.add(path.relative_to(directory).as_posix())
    if actual != expected:
        raise ValueError('complete_product_file_set')
    return {'status': 'exact_complete_core_projection_verified', 'files_including_manifest': len(actual),
            'product_bytes': total, 'manifest_sha256': hashlib.sha256(raw).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.directory)))


if __name__ == '__main__':
    main()
