"""Bounded, non-mutating preflight for the existing Sprint21 CAP worker.

This checks configuration and pinned files, not ACLs or arbitrary phase logic.
No subprocess is started here. The accepted runner remains authoritative.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time

CONFIG_CAP = 1024 * 1024
FILE_CAP = 128 * 1024 * 1024
TOTAL_CAP = 512 * 1024 * 1024
PIN_CAP = 2000
SECONDS = 20
PATH_FIELDS = ('workspace', 'pwsh', 'rustup_home', 'cargo_home', 'target',
               'temp', 'toolchain_bin', 'linker_self', 'linker_bin',
               'dlltool', 'linker', 'phase', 'output')
HEX = re.compile(r'[0-9A-F]{64}')
TRUSTED_WORKSPACE = Path(os.path.abspath(os.path.normpath(os.getcwd())))
RUNNER_FREEZE = datetime(2026, 10, 23, 0, 30, 37, tzinfo=timezone.utc)


class Rejected(ValueError):
    pass


def need(value, code):
    if not value:
        raise Rejected(code)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def path_key(value):
    need(isinstance(value, str) and 0 < len(value) <= 4096 and '\x00' not in value,
         'path_type')
    path = Path(value)
    need(path.is_absolute(), 'absolute_path_required')
    need(not value.startswith(('\\\\', '//')), 'network_path_refused')
    if os.name == 'nt':
        need(re.fullmatch(r'[A-Za-z]:', path.drive), 'local_drive_required')
        need(all(not part.endswith(('.', ' ')) and ':' not in part
                 for part in path.parts[1:] if part not in ('.', '..')),
             'ambiguous_windows_path')
    # Do not resolve links before checking them. normpath only normalizes syntax.
    normalized = Path(os.path.abspath(os.path.normpath(value)))
    parts = (normalized, *normalized.parents)
    # The caller's actual current directory is the explicit trust anchor. Its
    # OneDrive ancestors may be reparses; descendants and the anchor may not.
    if normalized == TRUSTED_WORKSPACE or inside(normalized, TRUSTED_WORKSPACE):
        parts = tuple(part for part in parts
                      if part == TRUSTED_WORKSPACE or inside(part, TRUSTED_WORKSPACE))
    for part in parts:
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        need(not stat.S_ISLNK(info.st_mode) and
             not (getattr(info, 'st_file_attributes', 0) &
                  getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400)),
             'reparse_path_refused')
    return os.path.normcase(str(normalized)), normalized


def inside(path, parent):
    try:
        path.relative_to(parent)
        return path != parent
    except ValueError:
        return False


def validate(workspace, config, expected):
    started = time.monotonic()

    def clock():
        need(time.monotonic() - started < SECONDS, 'preflight_deadline')

    need(isinstance(expected, str) and HEX.fullmatch(expected), 'config_sha_hex')
    workspace_key, workspace = path_key(str(workspace))
    need(workspace_key == os.path.normcase(str(TRUSTED_WORKSPACE)), 'workspace_cwd_binding')
    _, config = path_key(str(config))
    need(workspace.is_dir() and inside(config, workspace), 'config_workspace_binding')
    need(config.is_file() and config.stat().st_size <= CONFIG_CAP, 'config_size')
    raw = config.read_bytes()
    need(len(raw) <= CONFIG_CAP and hashlib.sha256(raw).hexdigest().upper() == expected,
         'config_identity')
    try:
        value = json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique_object,
                           parse_constant=lambda _: (_ for _ in ()).throw(Rejected('json_constant')))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise Rejected('invalid_json') from error
    need(isinstance(value, dict), 'config_object')
    # Validate the complete shape before reading any pinned payload.
    for name in PATH_FIELDS:
        need(name in value and isinstance(value[name], str) and value[name].strip(),
             'required_field_' + name)
    need('pwsh_sha' in value and isinstance(value['pwsh_sha'], str) and
         HEX.fullmatch(value['pwsh_sha']), 'pwsh_sha_hex')
    need(isinstance(value.get('pins'), list) and 0 < len(value['pins']) <= PIN_CAP,
         'pins_shape')
    need(path_key(value['workspace'])[0] == workspace_key, 'workspace_mismatch')
    for name in PATH_FIELDS:
        clock()
        path_key(value[name])
    owned_root = workspace / '.local' / 'sprint21' / 'root'
    _, output = path_key(value['output'])
    need(inside(output, owned_root) and not output.exists(), 'fresh_owned_output')
    if 'phase_deadline_utc' in value:
        deadline = value['phase_deadline_utc']
        need(isinstance(deadline, str) and
             re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', deadline),
             'phase_deadline_shape')
        try:
            parsed = datetime.strptime(deadline, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
        except ValueError as error:
            raise Rejected('phase_deadline_shape') from error
        need(parsed > datetime.now(timezone.utc), 'phase_deadline_expired')
        need(parsed <= RUNNER_FREEZE, 'accepted_runner_deadline_exceeded')
    else:
        need(datetime.now(timezone.utc) < RUNNER_FREEZE, 'accepted_runner_deadline_expired')
    pins = {}
    for row in value['pins']:
        clock()
        need(isinstance(row, dict) and set(row) == {'path', 'sha256'}, 'pin_shape')
        need(isinstance(row['sha256'], str) and HEX.fullmatch(row['sha256']),
             'pin_sha_hex')
        key, path = path_key(row['path'])
        need(key not in pins, 'duplicate_normalized_pin')
        pins[key] = (path, row['sha256'])
    for field in ('pwsh', 'phase'):
        key, _ = path_key(value[field])
        need(key in pins, 'mandatory_source_pin_' + field)
    need(pins[path_key(value['pwsh'])[0]][1] == value['pwsh_sha'], 'pwsh_pin_conflict')
    total = 0
    for path, expected_hash in pins.values():
        clock()
        need(path.is_file(), 'pin_regular_file')
        size = path.stat().st_size
        total += size
        need(size <= FILE_CAP and total <= TOTAL_CAP, 'pinned_byte_cap')
        digest = hashlib.sha256()
        read = 0
        with path.open('rb') as stream:
            while True:
                clock()
                block = stream.read(1024 * 1024)
                if not block:
                    break
                read += len(block)
                need(read <= size and read <= FILE_CAP, 'pin_changed_during_read')
                digest.update(block)
        need(read == size and digest.hexdigest().upper() == expected_hash, 'pin_identity')
    need(config.read_bytes() == raw, 'config_changed_during_check')
    clock()
    return {'status': 'CONFIGURATION_PREFLIGHT_ACCEPTED', 'config_sha256': expected,
            'pins_checked': len(pins), 'pinned_bytes_checked': total,
            'input_rewritten': False, 'native_feature_process_started': False,
            'acl_or_phase_logic_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--config', required=True)
    parser.add_argument('--config-sha', required=True)
    args = parser.parse_args()
    try:
        result = validate(args.workspace, args.config, args.config_sha)
    except (Rejected, OSError, RecursionError, ValueError) as error:
        # Never print local paths or exception text containing private content.
        code = str(error) if isinstance(error, Rejected) else 'file_access_failed'
        print(json.dumps({'status': 'CONFIGURATION_PREFLIGHT_REJECTED', 'code': code,
                          'input_rewritten': False, 'runner_delegated': False}))
        return 2
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
