"""Independent saved wrapper-control audit; no native/network execution."""
import hashlib
import json
import ntpath
from pathlib import Path
import sys
import time

bundle, output = map(Path, sys.argv[1:3])
projection = Path(sys.argv[3]) if len(sys.argv) == 4 else None
started = time.monotonic()
PWSH = '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
CODES = ['ACCEPTED', 'required_field_linker_self', 'pin_sha_hex',
         'pin_sha_hex', 'duplicate_normalized_pin', 'pin_identity']
FAKE = b'Synthetic data, not an executable.'
PHASE = b'# Synthetic fixture: must never execute.'
CHANGED = b'Changed synthetic bytes.'

def need(value, code):
    if not value:
        raise ValueError(code)

def read(path, cap=1024*1024):
    need(time.monotonic()-started < 45, 'audit deadline')
    need(path.is_file() and not path.is_symlink() and path.stat().st_size <= cap, 'bounded regular evidence')
    raw = path.read_bytes()
    need(len(raw) <= cap, 'file cap')
    return raw

def sha(raw):
    return hashlib.sha256(raw).hexdigest().upper()

def unique(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate saved JSON key')
        result[key] = value
    return result

def parse(raw):
    return json.loads(raw, object_pairs_hook=unique)

def load(path, cap=1024*1024):
    return parse(read(path, cap))

entries = load(projection, 2*1024*1024)['entries'] if projection else []
public_omissions = []

def original(path, digest, size):
    if path.exists():
        raw = read(path)
        need(len(raw) == size and sha(raw) == digest.upper(), 'original stream bytes/hash')
        return raw
    need(projection is not None, 'private original missing')
    relative = path.relative_to(projection.parent).as_posix()
    rows = [r for r in entries if r['public_path'] == relative and r['mode'] == 'omit']
    need(len(rows) == 1 and rows[0]['original_sha256'].upper() == digest.upper()
         and rows[0]['original_bytes'] == size, 'explicit original omission identity')
    public_omissions.append(relative)
    return None

captures = []
def capture(directory, label, expected):
    record = load(directory/(label+'.process.json'), 65536)
    start = load(directory/(label+'.start.json'), 65536)
    need(record['pid'] == start['pid'] and record['native_creation_utc'] == start['native_creation_utc'], 'actual capture identity')
    need(record['program_sha256'] == start['program_sha256'] == PWSH, 'pinned PowerShell identity')
    need(record['native_exit'] == expected and record['stdout_complete'] is True
         and record['stderr_complete'] is True, 'native exit and full EOF')
    need(not any(record.get(k) for k in ('capture_fault', 'drain_timeout', 'output_limit')), 'native capture fault')
    streams = {}
    for side in ('stdout', 'stderr'):
        streams[side] = original(directory/(label+'.'+side), record[side+'_sha256'], record[side+'_bytes_persisted'])
    captures.append({'label': label, 'pid': record['pid'], 'creation_utc': record['native_creation_utc'], 'native_exit': expected})
    return record, streams

report = load(bundle/'preflight-controls-proof.json', 128*1024)
need(report['status'] == 'SIX_FINITE_SYNTHETIC_PREFLIGHT_CONTROLS_PASS'
     and report['feature_processes_started'] is False
     and report['existing_runner_delegated'] is False
     and report['historical_configs_rewritten'] is False
     and report['historical_unknowns_reconstructed'] is False, 'finite control scope')
need([r['id'] for r in report['controls']] == ['PREFLIGHT%02d' % i for i in range(1, 7)], 'exact six stable controls')
need(len(list(bundle.glob('*.process.json'))) == 1, 'one original phase owner capture')
capture(bundle, 'command', 0)
checked = []
for number, row in enumerate(report['controls'], 1):
    directory = bundle/row['id']
    need(len(list(directory.glob('*.process.json'))) == 1, 'one original wrapper capture per case')
    exit_code = 0 if number == 1 else 2
    need(row['native_exit'] == row['expected_exit'] == exit_code
         and row['check_only'] is (number == 1) and row['code'] == CODES[number-1]
         and row['runner_marker_absent'] is True and row['runner_output_absent'] is True
         and row['all_streams_eof'] is True, 'reported default-mode/CheckOnly semantics')
    need(row['config_sha256'] == row['config_after_sha256'], 'reported immutable input')
    record, streams = capture(directory, 'wrapper', exit_code)
    need(row['stdout_sha256'] == record['stdout_sha256']
         and row['stderr_sha256'] == record['stderr_sha256'], 'report/capture original stream binding')
    need(streams['stdout'] is not None and streams['stderr'] == b'', 'wrapper actual complete streams required')
    need(b'RUNNER_DELEGATION' not in streams['stdout'], 'no delegate gate reached')
    actual = parse(streams['stdout'])
    need(actual['input_rewritten'] is False, 'validator non-mutating result')
    if number == 1:
        need(actual['status'] == row['status'] == 'CONFIGURATION_PREFLIGHT_ACCEPTED'
             and actual['config_sha256'] == row['config_sha256']
             and actual['pins_checked'] == 2 and actual['pinned_bytes_checked'] == len(FAKE)+len(PHASE)
             and actual['native_feature_process_started'] is False
             and actual['acl_or_phase_logic_verified'] is False, 'actual CheckOnly accepted result')
    else:
        need(actual['status'] == row['status'] == 'CONFIGURATION_PREFLIGHT_REJECTED'
             and actual['code'] == CODES[number-1] and actual['runner_delegated'] is False,
             'actual default-mode pre-delegation refusal')
    need(not (directory/'must-not-be-created').exists(), 'runner output absent in saved tree')
    need(read(directory/'synthetic-not-executable.txt', 256) == FAKE, 'synthetic nonexecutable bytes')
    phase = read(directory/'synthetic-never-executed.ps1', 256)
    need(phase == (CHANGED if number == 6 else PHASE), 'synthetic phase bytes')
    config_path = directory/'fixture-config.json'
    private_config_checked = False
    if config_path.exists():
        raw = read(config_path)
        need(sha(raw) == row['config_sha256'], 'actual immutable fixture config identity')
        value = parse(raw)
        if number == 2:
            need(all(k not in value for k in ('linker_self', 'linker_bin', 'dlltool', 'linker')), 'actual missing worker fields')
        else:
            need(all(isinstance(value.get(k), str) and value[k] for k in
                     ('workspace', 'pwsh', 'rustup_home', 'cargo_home', 'target', 'temp',
                      'toolchain_bin', 'linker_self', 'linker_bin', 'dlltool', 'linker', 'phase', 'output')), 'positive fixture mandatory fields')
        pins = value['pins']
        if number == 3:
            need(pins[0]['sha256'] == sha(FAKE).lower() and pins[0]['sha256'] != sha(FAKE), 'actual lowercase corruption')
        elif number == 4:
            need(pins[0]['sha256'] == 'G'*64, 'actual invalid hex corruption')
        elif number == 5:
            key = lambda s: ntpath.normcase(ntpath.normpath(s))
            need(len(pins) == 3 and key(pins[0]['path']) == key(pins[2]['path'])
                 and pins[0]['sha256'] != pins[2]['sha256'], 'actual normalized conflicting duplicate')
        elif number == 6:
            need(pins[1]['sha256'] == sha(PHASE) != sha(phase), 'actual changed bytes corruption')
        private_config_checked = True
    else:
        need(projection is not None, 'private fixture config missing')
        relative = config_path.relative_to(projection.parent).as_posix()
        omitted = [r for r in entries if r['public_path'] == relative and r['mode'] == 'omit']
        need(len(omitted) == 1 and omitted[0]['original_sha256'].upper() == row['config_sha256']
             and 0 < omitted[0]['original_bytes'] <= 1024*1024, 'omitted fixture config original hash link')
        public_omissions.append(relative)
    checked.append({'id': row['id'], 'actual_exit': exit_code, 'code': CODES[number-1],
                    'check_only': number == 1, 'delegate_marker_absent': True,
                    'private_fixture_content_independently_checked': private_config_checked,
                    'fixture_config_sha256': row['config_sha256']})
need(len(captures) == 7 and not output.exists(), 'exact seven direct captures and fresh proof')
output.write_text(json.dumps({'status': 'INDEPENDENT_SIX_SAVED_WRAPPER_CONTROLS_VERIFIED',
    'controls': checked, 'direct_phase_and_wrapper_captures': captures,
    'all_direct_capture_stream_lengths_hashes_and_eof_verified': True,
    'public_original_omissions': public_omissions, 'native_or_network_executed_by_auditor': False,
    'limitations': ['Validator Python stdout/stderr is inherited through each synchronous wrapper; no separate validator PID identity record is claimed.',
                    'Default-mode versus CheckOnly binding combines reviewed control-source dominance and saved control report; private invocation arguments are not independently recorded.',
                    'Omitted public fixture configs are hash-linked only; their contents are not claimed publicly audited.',
                    'No product, PostgreSQL, phase logic, ACL, resource timeout cause or historical UNKNOWN repair is established.']}, indent=2), encoding='utf-8')
