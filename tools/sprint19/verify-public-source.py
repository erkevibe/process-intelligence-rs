"""Compare every public commit archive file with the exact local Git archive."""
import argparse
import hashlib
import json
import stat
import zipfile
from pathlib import Path, PurePosixPath


def inventory(path, prefix):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('bounded_regular_archive')
    rows, total = {}, 0
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if not 1 <= len(entries) <= 10000:
            raise ValueError('bounded_entries')
        for entry in entries:
            if not entry.filename.startswith(prefix):
                raise ValueError('exact_archive_prefix')
            name = entry.filename[len(prefix):]
            if entry.is_dir():
                continue
            member = PurePosixPath(name)
            if (not name or member.is_absolute() or '..' in member.parts or ':' in name
                    or '\\' in name or member.as_posix() != name or name in rows
                    or stat.S_ISLNK(entry.external_attr >> 16) or entry.flag_bits & 1):
                raise ValueError('unique_safe_regular_member')
            total += entry.file_size
            if entry.file_size > 32 * 1024 * 1024 or total > 128 * 1024 * 1024:
                raise ValueError('bounded_uncompressed_bytes')
            data = archive.read(entry)
            if len(data) != entry.file_size:
                raise ValueError('full_member_bytes')
            rows[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    return rows, total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('expected', type=Path)
    parser.add_argument('public', type=Path)
    parser.add_argument('commit')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if len(args.commit) != 40 or any(char not in '0123456789abcdef' for char in args.commit):
        raise ValueError('exact_commit')
    expected, total = inventory(args.expected, '')
    observed, observed_total = inventory(args.public, 'process-intelligence-rs-' + args.commit + '/')
    if expected != observed or total != observed_total:
        raise ValueError('entire_public_commit_file_set_and_every_byte_hash')
    result = {'schema_version': 1, 'status': 'ENTIRE_ANONYMOUS_PUBLIC_COMMIT_ARCHIVE_VERIFIED',
              'commit': args.commit, 'files': len(observed), 'uncompressed_bytes': total,
              'public_zip_sha256': hashlib.sha256(args.public.read_bytes()).hexdigest(),
              'local_git_archive_sha256': hashlib.sha256(args.expected.read_bytes()).hexdigest(),
              'all_files': observed, 'no_native_engine_executed': True}
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print(json.dumps({key: result[key] for key in ['status', 'commit', 'files', 'uncompressed_bytes', 'public_zip_sha256']}))


if __name__ == '__main__':
    main()
