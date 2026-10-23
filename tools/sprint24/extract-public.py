"""Extract only the replay subset after complete public Git ZIP verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import time
import zipfile


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def bounded_read(path, cap):
    with path.open('rb') as stream:
        raw = stream.read(cap + 1)
    need(len(raw) <= cap, 'bounded_read')
    return raw


def main():
    parser = argparse.ArgumentParser()
    for name in ('archive', 'verification', 'out', 'proof'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--verification-sha', required=True)
    args = parser.parse_args()
    for name in ('archive', 'verification', 'out', 'proof'):
        setattr(args, name, Path(os.path.abspath(getattr(args, name))))
    started = time.monotonic()
    workspace = Path.cwd().resolve(strict=True)
    for path in (args.archive, args.verification, args.out, args.proof):
        path = path.absolute()
        need(path.is_relative_to(workspace / '.local/sprint21/root/sprint24'), 'owned_private_scope')
        current = workspace
        for part in path.relative_to(workspace).parts:
            current /= part
            if current.exists() or current.is_symlink():
                st = current.lstat()
                need(not current.is_symlink() and not getattr(st, 'st_file_attributes', 0) & 1024, 'reparse_descendant')
    need(args.out.is_dir() and not any(args.out.iterdir()) and not args.proof.exists(), 'fresh_outputs')
    need(len(args.commit) == 40 and all(c in '0123456789abcdef' for c in args.commit), 'exact_commit')
    proof_raw = bounded_read(args.verification, 4 * 1024 * 1024)
    need(len(args.verification_sha) == 64 and sha(proof_raw).upper() == args.verification_sha.upper(),
         'exact_owned_verification_proof')
    verification = json.loads(proof_raw)
    need(verification['status'] == 'ENTIRE_ANONYMOUS_PUBLIC_COMMIT_ARCHIVE_VERIFIED' and
         verification['commit'] == args.commit, 'prior_whole_git_verification')
    need(type(verification['files']) is int and 1 <= verification['files'] <= 10000 and
         isinstance(verification['all_files'], dict) and
         len(verification['all_files']) == verification['files'] and
         type(verification['uncompressed_bytes']) is int and
         0 <= verification['uncompressed_bytes'] <= 128 * 1024 * 1024, 'whole_verification_bounds')
    need(sha(bounded_read(args.archive, 32 * 1024 * 1024)) == verification['public_zip_sha256'], 'same_verified_zip')
    exact = {'tools/sprint20/verify-evidence-manifest.py', '.gitattributes', '.github/workflows/ci.yml',
             'docs/CAPACITY_DIAGNOSTIC.md', 'docs/DATABASE_RECOVERY.md', 'docs/SPRINT_24_REPORT.md'}
    wanted = {name: row for name, row in verification['all_files'].items()
              if name in exact or name.startswith(('tools/sprint24/', 'evidence/sprint24/'))}
    need(exact <= set(wanted) and 1 <= len(wanted) <= 1000, 'fixed_subset')
    need(len({name.casefold() for name in wanted}) == len(wanted), 'casefold_unique_subset')
    prefix = 'process-intelligence-rs-' + args.commit + '/'
    total, rows = 0, []
    with zipfile.ZipFile(args.archive) as archive:
        for name, row in sorted(wanted.items()):
            need(time.monotonic() - started < 90, 'extraction_deadline')
            relative = PurePosixPath(name)
            need(relative.as_posix() == name and not relative.is_absolute() and
                 all(p not in ('.', '..') for p in relative.parts) and ':' not in name and '\\' not in name, 'portable_member')
            entry = archive.getinfo(prefix + name)
            need(0 <= entry.file_size <= 4 * 1024 * 1024, 'member_bound')
            with archive.open(entry) as stream:
                raw = stream.read(4 * 1024 * 1024 + 1)
            need(len(raw) == entry.file_size == row['bytes'] and sha(raw) == row['sha256'], 'verified_member_identity')
            total += len(raw)
            need(total <= 16 * 1024 * 1024, 'subset_total_bound')
            target = args.out.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as stream:
                stream.write(raw)
            rows.append({'path': name, 'bytes': len(raw), 'sha256': sha(raw)})
    result = {'status': 'WHOLE_GIT_VERIFIED_ONLY_FIXED_REPLAY_SUBSET_EXTRACTED',
              'commit': args.commit, 'whole_files_verified': verification['files'],
              'extracted_files': len(rows), 'extracted_bytes': total, 'files': rows,
              'scope': 'Complete archive retained and verified; extraction limited to declared replay sources/evidence/docs. No product or DB execution.'}
    with args.proof.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
    print(json.dumps({k: result[k] for k in ('status', 'commit', 'whole_files_verified', 'extracted_files', 'extracted_bytes')}))


if __name__ == '__main__':
    main()
