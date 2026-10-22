"""Verify the frozen failure-evidence projection; never infer stage success."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

bundle, expected, output = Path(sys.argv[1]), sys.argv[2].upper(), Path(sys.argv[3])
policy = Path(__file__).absolute().with_name('project-public-evidence.py')
raw_policy = policy.read_bytes()
assert hashlib.sha256(raw_policy).hexdigest().upper() == 'BF1C8A42DA73CA7D1592F26F0BBC3B302EC705A7B208AC5B9C2BD44B06E91658'
spec = importlib.util.spec_from_file_location('fixed_projection_policy', policy)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
started = time.monotonic()
manifest = bundle / 'projection-manifest.json'
raw = p.bounded(manifest, boundary=bundle)
p.require(p.sha(raw).upper() == expected, 'fixed_manifest_identity')
m = json.loads(raw)
p.require(m['schema_version'] == 1 and 0 < len(m['entries']) <= 2000, 'manifest_shape')
required = {'projection-manifest.json'}
omitted = aliases = 0
total = 0
for row in m['entries']:
    p.require(time.monotonic() - started < 60, 'public_package_deadline')
    name = row['public_path']
    p.relative(name)
    path = bundle / name
    if row['mode'] == 'omit':
        p.require(not path.exists(), 'omitted_file_present')
        omitted += 1
        continue
    p.require(name not in required, 'duplicate_public_file')
    required.add(name)
    data = p.bounded(path, boundary=bundle)
    p.require(len(data) == row['public_bytes'] and p.sha(data) == row['public_sha256'], 'public_file_identity')
    total += len(data)
    p.require(total <= 100 * 1024 * 1024, 'public_total_cap')
    p.require(row['mode'] in ('bytes', 'json_paths'), 'projection_mode')
    if row['mode'] == 'bytes':
        p.require(row['original_sha256'] == row['public_sha256'] and row['original_bytes'] == row['public_bytes'], 'byte_exact_projection')
    else:
        aliases += 1
        p.require(all(x.rsplit('/', 1)[-1] == 'program' for x in row['json_pointers']), 'only_program_aliases')
    if data.lstrip().startswith((b'{', b'[')):
        numbers = p.numeric_tokens(p.parse(data))
        p.require(numbers == row['numeric_tokens_sha256_before'] == row['numeric_tokens_sha256_after'], 'numeric_tokens_original_lexemes')
    p.machine_leak(data, bundle, Path.home().absolute())
actual = set()
for path in bundle.rglob('*'):
    p.no_reparse(path)
    if path.is_file():
        actual.add(path.relative_to(bundle).as_posix())
p.require(actual == required, 'exact_public_file_set')
p.require(total == m['public_bytes'], 'manifest_total')
p.require(not output.exists(), 'fresh_package_proof')
with output.open('x', encoding='utf-8', newline='\n') as stream:
    json.dump({'status':'FIXED_FAILURE_PACKAGE_ALL_OUTPUTS_AND_NUMERIC_TOKENS_PASS', 'manifest_sha256':expected,
               'files':len(actual), 'entries':len(m['entries']), 'omitted':omitted, 'program_alias_records':aliases,
               'public_data_bytes':total, 'stage_success_not_claimed':True,
               'native_engine_or_network_executed':False}, stream, indent=2)