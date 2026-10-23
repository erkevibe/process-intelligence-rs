"""Finite privacy policy controls against immutable OWN05 data; no child/network."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

workspace, output = map(Path, sys.argv[1:3])
workspace = workspace.absolute()
started = time.monotonic()
source = workspace / 'tools/sprint22/project-public-evidence.py'
pin = 'E29223B3CB01729BAB84A1979D80C6F7EAEE1A8CCAF6EE90C4FDAD8DD2EBFB88'


def need(value, code):
    if not value:
        raise ValueError(code)


def bounded(path, cap=1024 * 1024):
    need(time.monotonic() - started < 30, 'control_deadline')
    need(path.is_relative_to(workspace) and path.stat().st_size <= cap, 'contained_small_input')
    current = path
    while current != workspace:
        need(not current.is_symlink() and not (getattr(current.lstat(), 'st_file_attributes', 0) & 1024), 'no_reparse')
        current = current.parent
    return path.read_bytes()


need(not output.exists(), 'fresh_output')
need(hashlib.sha256(bounded(source)).hexdigest().upper() == pin, 'projector_pin')
spec = importlib.util.spec_from_file_location('s22_projection_policy', source)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
private = workspace / '.local/sprint21/root/sprint22/controls04'
raw = bounded(private / 'own-05/broker-result.json')
original = p.parse(raw)
allowed = {'/guard_failure/target'}
guard_pointer = {'/guard_failure/message'}
profile = Path.home().absolute()
expected_alias = 'workspace:/.local/sprint21/root/sprint22/controls04/own-05/guard-denial.bin'


def clone():
    return p.parse(p.emit(original).encode())


projected = p.transform(clone(), allowed, workspace, profile, guard_allowed=guard_pointer)
expected = clone()
expected['guard_failure']['target'] = expected_alias
expected['guard_failure']['message'] = "The process cannot access the file '" + expected_alias + "' because it is being used by another process."
need(projected == expected, 'exact_two_selected_string_changes_only')
need(p.numeric_tokens(projected) == p.numeric_tokens(original), 'all_numeric_lexemes_unchanged')
p.machine_leak((p.emit(projected) + '\n').encode(), workspace, profile)
cases = []


def rejects(name, mutate=None, aliases=allowed, guards=guard_pointer, uris=frozenset()):
    value = clone()
    if mutate:
        mutate(value['guard_failure'])
    try:
        p.transform(value, aliases, workspace, profile, uri_allowed=uris, guard_allowed=guards)
    except ValueError:
        cases.append(name)
    else:
        raise ValueError('negative_control_accepted_' + name)


rejects('wrong_hresult', lambda g: g.update(hresult=p.Number('-2147024891')))
rejects('hresult_string_not_number', lambda g: g.update(hresult='-2147024864'))
rejects('wrong_exception_type', lambda g: g.update(type='System.Exception'))
rejects('wrong_sharing_marker', lambda g: g.update(expected_owned_sharing_failure=False))
rejects('wrong_target', lambda g: g.update(target=str(workspace / 'other.bin')))
rejects('extra_message_text', lambda g: g.update(message=g['message'] + ' additional text'))
rejects('second_embedded_path', lambda g: g.update(message=g['message'] + ' C:\\other\\secret.bin'))
rejects('missing_target_alias_pointer', aliases=set())
rejects('overlapping_path_pointer', aliases=allowed | guard_pointer)
rejects('overlapping_uri_pointer', uris=guard_pointer)
rejects('unknown_guard_pointer', guards={'/guard_failure/type'})

routes = ['/setup', '/projects', '/project-list/json', '/projects/project-' + 'a' * 32 + '/open']
for route in routes:
    need(p.relative_uri(route, workspace, profile) == route, 'exact_relative_route')
for route in ['/projects/project-' + 'a' * 31 + '/open', '/projects/project-' + 'A' * 32 + '/open', '/projects/project-' + 'a' * 32 + '/open?x=1', '/projects/project-' + 'a' * 32 + '/open/more', '//foreign/projects', 'https://foreign/projects', '/project-list/jsonx']:
    try:
        p.relative_uri(route, workspace, profile)
    except ValueError:
        cases.append('refused_route_' + str(len(cases)))
    else:
        raise ValueError('unknown_route_accepted')

records = 0
for record_path in sorted(private.glob('own-*/*.process.json')):
    before = p.parse(bounded(record_path))
    after = p.transform(before, {'/program'}, workspace, profile)
    need(p.numeric_tokens(before) == p.numeric_tokens(after), 'native_integer_lexemes')
    need({k: v for k, v in before.items() if k != 'program'} == {k: v for k, v in after.items() if k != 'program'}, 'all_nonprogram_native_fields_unchanged')
    for key in ['stdout_sha256', 'stderr_sha256', 'program_sha256']:
        if key in before:
            need(before[key] == after[key], 'original_capture_sha_not_rebound')
    records += 1
need(records == 14 and len(cases) == 18, 'finite_control_inventory')
memory_sources = []
for tag in ['10k', '90k', 'adapter-complete', 'adapter-partial']:
    if tag.startswith('adapter-'):
        leaf = 'dead-target.ndjson' if tag == 'adapter-partial' else 'memory.ndjson'
        source_name = '.local/sprint21/root/sprint22/adapter01/memory/' + leaf
        public_name = 'adapter/memory/' + leaf
    else:
        source_name = '.local/sprint21/root/sprint22/measurement01/memory-' + tag + '.ndjson'
        public_name = 'measurement/memory-' + tag + '.ndjson'
    memory_raw = bounded(workspace / source_name, 4 * 1024 * 1024)
    values = p.validate_memory_ndjson(memory_raw, source_name, public_name, workspace, profile)
    p.machine_leak(memory_raw, workspace, profile, ndjson=True)
    memory_sources.append({'tag': tag, 'bytes': len(memory_raw), 'sha256': hashlib.sha256(memory_raw).hexdigest().upper(), 'lines': len(values)})
    lines = memory_raw.splitlines()
    def changed_header(key, value):
        header = p.parse(lines[0]); header[key] = value
        return p.emit(header).encode() + b'\n' + b'\n'.join(lines[1:]) + b'\n'
    negative = [
        ('wrong_source', memory_raw, source_name + '.extra', public_name),
        ('wrong_public', memory_raw, source_name, public_name + '.extra'),
        ('missing_final_lf', memory_raw[:-1], source_name, public_name),
        ('bad_json', b'{broken}\n' + b'\n'.join(lines[1:]) + b'\n', source_name, public_name),
        ('footer_boundary', memory_raw + b'{"kind":"complete","samples":1,"target_still_alive":true}\n' if tag == 'adapter-partial' else b'\n'.join(lines[:-1]) + b'\n', source_name, public_name),
        ('absolute_path', changed_header('machine_path', 'C:\\private\\not-read'), source_name, public_name),
        ('sensitive_key', changed_header('password', 'synthetic-test-value'), source_name, public_name),
    ]
    for name, data, src, public in negative:
        try:
            p.validate_memory_ndjson(data, src, public, workspace, profile)
        except ValueError:
            cases.append('memory_' + tag + '_' + name)
        else:
            raise ValueError('memory_negative_accepted_' + name)
for tag in ['10k', '90k']:
    source_name = '.local/sprint21/root/sprint22/measurement01/session/app' + tag + '.stderr'
    public_name = 'measurement/session/app' + tag + '.stderr'
    app_raw = bounded(workspace / source_name, 4 * 1024 * 1024)
    values = p.validate_memory_ndjson(app_raw, source_name, public_name, workspace, profile)
    p.machine_leak(app_raw, workspace, profile, ndjson=True)
    memory_sources.append({'tag': 'app-' + tag, 'bytes': len(app_raw), 'sha256': hashlib.sha256(app_raw).hexdigest().upper(), 'lines': len(values)})
    lines = app_raw.splitlines()
    def changed_app(kind):
        value = p.parse(lines[0])
        if kind == 'absolute_path':
            value['fields']['message'] = 'C:\\private\\not-read'
        elif kind == 'sensitive_key':
            value['fields']['password'] = 'synthetic-test-value'
        elif kind == 'bad_path_uri':
            value['fields']['path'] = 'https://foreign.invalid/private'
        else:
            value['unexpected_schema_field'] = True
        return p.emit(value).encode() + b'\n' + b'\n'.join(lines[1:]) + b'\n'
    negative = [
        ('wrong_source', app_raw, source_name + '.extra', public_name),
        ('wrong_public', app_raw, source_name, public_name + '.extra'),
        ('missing_final_lf', app_raw[:-1], source_name, public_name),
        ('bad_json', b'{broken}\n' + b'\n'.join(lines[1:]) + b'\n', source_name, public_name),
        ('absolute_path', changed_app('absolute_path'), source_name, public_name),
        ('sensitive_key', changed_app('sensitive_key'), source_name, public_name),
        ('bad_schema', changed_app('bad_schema'), source_name, public_name),
        ('bad_path_uri', changed_app('bad_path_uri'), source_name, public_name),
    ]
    for name, data, src, public in negative:
        try:
            p.validate_memory_ndjson(data, src, public, workspace, profile)
        except ValueError:
            cases.append('app_' + tag + '_' + name)
        else:
            raise ValueError('app_negative_accepted_' + name)
need(len(cases) == 62 and len(memory_sources) == 6, 'final_finite_control_inventory')
need(time.monotonic() - started < 30, 'control_deadline')
with output.open('x', encoding='utf-8') as stream:
    json.dump({'status': 'FINITE_S22_PRIVACY_CONTROLS_VERIFIED', 'projector_sha256': pin, 'actual_own05_original_sha256': hashlib.sha256(raw).hexdigest().upper(), 'positive_known_guard_projection': True, 'rejected_controls': cases, 'positive_relative_routes': len(routes), 'native_records_original_numbers_and_capture_hashes_unchanged': records, 'memory_ndjson_sources': memory_sources, 'publication_performed': False}, stream, indent=2)
