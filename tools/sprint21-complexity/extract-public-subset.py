"""Extract bounded new-stage subset only AFTER entire exact Git ZIP verification."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import time
import zipfile

archive, head, output, verification, proof = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]), Path(sys.argv[5])
started = time.monotonic()
def need(value, message):
    if not value:
        raise ValueError(message)
def sha(data):
    return hashlib.sha256(data).hexdigest()
need(len(head) == 40 and all(c in '0123456789abcdef' for c in head), 'exact head')
need(verification.stat().st_size <= 4*1024*1024 and not verification.is_symlink(), 'verification bound')
verified = json.loads(verification.read_bytes())
need(verified['status'] == 'ENTIRE_ANONYMOUS_PUBLIC_COMMIT_ARCHIVE_VERIFIED' and verified['commit'] == head, 'whole verified commit')
need(archive.stat().st_size <= 32*1024*1024 and not archive.is_symlink(), 'archive bound')
need(sha(archive.read_bytes()) == verified['public_zip_sha256'].lower(), 'same verified entire archive')
need(output.is_dir() and not output.is_symlink() and not any(output.iterdir()) and not proof.exists(), 'fresh owned empty output')
root = output.resolve()
prefix = 'process-intelligence-rs-'+head+'/'
folders = ('evidence/sprint21-complexity/', 'tools/sprint21-complexity/', 'flw/records/sprint21-complexity/')
files = {'tools/sprint21/project-public-evidence.py', 'docs/SPRINT_21_EVENT_COMPLEXITY_REPORT.md'}
seen, extracted, total = set(), [], 0
with zipfile.ZipFile(archive) as source:
    for entry in source.infolist():
        need(time.monotonic()-started < 45, 'subset deadline')
        need(entry.filename.startswith(prefix), 'exact archive root')
        name = entry.filename[len(prefix):]
        if not name or entry.is_dir():
            continue
        if not (name.startswith(folders) or name in files):
            continue
        path = PurePosixPath(name)
        need(not path.is_absolute() and all(x not in ('', '.', '..') and ':' not in x and '\\' not in x for x in path.parts), 'relative portable subset')
        need(name not in seen and not stat.S_ISLNK(entry.external_attr >> 16), 'unique nonlink subset')
        seen.add(name)
        need(len(seen) <= 512 and entry.file_size <= 25*1024*1024, 'subset entry bounds')
        total += entry.file_size
        need(total <= 64*1024*1024, 'subset total bound')
        with source.open(entry) as stream:
            data = stream.read(25*1024*1024+1)
        expected = verified['all_files'].get(name)
        need(expected is not None and len(data) == entry.file_size == expected['bytes'] and sha(data) == expected['sha256'], 'verified subset member')
        destination = output.joinpath(*path.parts)
        need(destination.resolve().is_relative_to(root), 'contained destination')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as stream:
            stream.write(data)
        extracted.append({'path':name, 'bytes':len(data), 'sha256':sha(data)})
need(files <= seen and len(extracted) > 2, 'required subset present')
with proof.open('x', encoding='utf-8') as stream:
    json.dump({'status':'VERIFIED_ENTIRE_ZIP_THEN_BOUNDED_NEW_STAGE_SUBSET_EXTRACTED', 'commit':head,
               'whole_git_files_verified':verified['files'], 'subset_files':len(extracted), 'subset_bytes':total,
               'files':extracted, 'product_engine_executed':False},stream,indent=2)