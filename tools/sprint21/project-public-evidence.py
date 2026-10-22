"""Explicit, bounded S21 public projection. Never rebind native capture hashes.

Only explicitly listed JSON-pointer string VALUES may acquire path aliases.
Numbers retain their original lexical spelling; scientific byte payloads are exact.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import time

MAX_ENTRIES = 2000
MAX_FILE = 25 * 1024 * 1024
MAX_TOTAL = 100 * 1024 * 1024
MANIFEST_CAP = 2 * 1024 * 1024
# Windows validation of the measured 967-file package exceeded 25 seconds
# before output creation. Keep a finite wall bound alongside all byte caps.
MAX_SECONDS = 90
FROZEN_CORPUS_SHA256 = '621dc9106835eb3274659a08f033da4b74ef7cce9a58846e4b01788c866cfe34'
SENSITIVE_NAME = re.compile(r"(?i)(?:private[-_]credentials|postgres[-_]private|credentials|password|session[-_]cookie|pi_kv)")
SENSITIVE_KEY = re.compile(r"(?i)^(?:auth|authorization|password|password_hash|passwd|session|sessions|session_id|session_token|token|access_token|refresh_token|cookie|cookies|secret|credentials|connection_string|database_url)$")
ABSOLUTE = re.compile(r"(?i)(?:(?<![a-z0-9])file:/+|(?<![a-z0-9])[a-z]:[\\/]|\\\\[^\\/]+[\\/]|^/)")
SECRET_TEXT = re.compile(r'''(?i)(?:postgres(?:ql)?://[^\s/@:]+:[^\s/@]+@|(?:password|password_hash|passwd|authorization|access_token|refresh_token|session_token|session|token|secret)["']?\s*[:=]\s*[^\s,;}]+|pi_session=)''')

class Number(str):
    """A JSON number lexeme, never a string or a floating-point conversion."""


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def parse(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'duplicate_json_key')
            result[key] = value
        return result
    return json.loads(raw.decode('utf-8', errors='strict'), parse_int=Number,
                      parse_float=Number, object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite_json')))


def emit(value):
    if isinstance(value, Number):
        return str(value)
    if value is None:
        return 'null'
    if value is True:
        return 'true'
    if value is False:
        return 'false'
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return '[' + ','.join(emit(item) for item in value) + ']'
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(key, ensure_ascii=False) + ':' + emit(item) for key, item in value.items()) + '}'
    raise ValueError('unhandled_json_value')


def numeric_tokens(value):
    tokens = []
    def walk(item):
        if isinstance(item, Number):
            tokens.append(str(item))
        elif isinstance(item, list):
            for child in item:
                walk(child)
        elif isinstance(item, dict):
            for child in item.values():
                walk(child)
    walk(value)
    return sha('\n'.join(tokens).encode('ascii'))


def no_reparse(path):
    info = path.lstat()
    require(not path.is_symlink() and not (getattr(info, 'st_file_attributes', 0) & 1024), 'reparse_path')
    return info


def inside(root, path):
    return os.path.normcase(os.path.commonpath((str(root), str(path)))) == os.path.normcase(str(root))


def chain(path, boundary):
    # The supplied workspace is the explicit trust anchor. Cloud-managed
    # ancestors above it are outside this operation; every in-scope component,
    # including the workspace itself, must still be an ordinary file/directory.
    require(inside(boundary, path), 'path_outside_trusted_workspace')
    no_reparse(boundary)
    current = boundary
    for part in path.relative_to(boundary).parts:
        current = current / part
        no_reparse(current)


def relative(value):
    require(isinstance(value, str) and value and '\\' not in value and ':' not in value and '\x00' not in value, 'relative_path_required')
    path = PurePosixPath(value)
    require(not path.is_absolute() and all(part not in ('', '.', '..') for part in value.split('/')), 'relative_path_required')
    require(all(not part.endswith(('.', ' ')) and re.fullmatch(r'(?i)(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', part) is None for part in path.parts), 'ambiguous_windows_path')
    return path


def contained(root, value):
    target = root.joinpath(*relative(value).parts)
    require(os.path.commonpath((str(root), str(target))) == str(root), 'path_escape')
    return target


def stable_read_identity(path_before, handle_before, handle_after, path_after, platform=None):
    def identity(stat, ctime=True):
        fields = (stat.st_dev, stat.st_ino, stat.st_mode, stat.st_size, stat.st_mtime_ns,
                  getattr(stat, 'st_birthtime_ns', None), getattr(stat, 'st_file_attributes', None))
        return fields + ((stat.st_ctime_ns,) if ctime else ())
    # Actual Windows 3.13 calibration records lstat ctime as creation time and
    # fstat ctime as modification time, with birthtime equal. Each observation
    # family must remain completely stable, including its own ctime. Only the
    # cross-family comparison omits this calibrated Windows representation gap.
    if identity(path_before) != identity(path_after) or identity(handle_before) != identity(handle_after):
        return False
    cross_ctime = (os.name if platform is None else platform) != 'nt'
    return identity(path_before, cross_ctime) == identity(handle_before, cross_ctime)


def bounded(path, limit=MAX_FILE, boundary=None):
    require(boundary is not None, 'trusted_workspace_required')
    chain(path, boundary)
    info = no_reparse(path)
    require(path.is_file() and info.st_size <= limit, 'regular_bounded_file_required')
    with path.open('rb') as stream:
        before = os.fstat(stream.fileno())
        raw = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    chain(path, boundary)
    current = no_reparse(path)
    require(len(raw) <= limit and len(raw) == info.st_size and stable_read_identity(info, before, after, current), 'source_changed')
    return raw


def alias(text, workspace, profile):
    for base, label in ((workspace, 'workspace:/'), (profile, 'userprofile:/')):
        variants = {str(base), base.as_posix(), 'file:/' + base.as_posix(), 'file:///' + base.as_posix()}
        for prefix in sorted(variants, key=len, reverse=True):
            if text[:len(prefix)].casefold() == prefix.casefold():
                suffix = text[len(prefix):]
                require(not suffix or suffix[0] in '/\\', 'path_prefix_boundary')
                require(not any(part in ('.', '..') for part in suffix.replace('\\', '/').split('/')), 'path_dot_segment')
                return label + suffix.lstrip('/\\').replace('\\', '/')
    raise ValueError('unknown_absolute_path_alias')


def pointer_part(text):
    return text.replace('~', '~0').replace('/', '~1')


def pointer_valid(pointer):
    return isinstance(pointer, str) and (pointer == '' or pointer.startswith('/')) and re.search(r'~(?![01])', pointer) is None


def relative_uri(value, workspace, profile):
    require(isinstance(value, str) and not isinstance(value, Number), 'uri_pointer_not_string')
    require('\\' not in value and not value.startswith('//') and '..' not in value.split('/') and ':' not in value, 'invalid_relative_uri')
    for base in (workspace, profile):
        for variant in (str(base), base.as_posix()):
            require(variant.casefold() not in value.casefold(), 'machine_path_in_uri')
    routes = r'/(?:conversions(?:/jobs/job-[0-9]{1,32}(?:/(?:payload|report|events|cancel|retry|delete))?)?|jobs(?:/job-[0-9]{1,32}(?:/(?:events|cancel))?)?|health|backup|restore)?'
    require(re.fullmatch(routes, value) is not None, 'unknown_relative_uri')
    return value


def transform(value, allowed, workspace, profile, uri_allowed=frozenset()):
    used = set()
    used_uri = set()
    def walk(item, pointer=''):
        if isinstance(item, Number):
            require(pointer not in allowed | uri_allowed, 'pointer_not_string')
            return item
        if isinstance(item, str):
            require(not SECRET_TEXT.search(item), 'sensitive_material')
            if pointer in uri_allowed:
                used_uri.add(pointer)
                return relative_uri(item, workspace, profile)
            if pointer in allowed:
                require(ABSOLUTE.search(item), 'pointer_not_absolute_path')
                projected = alias(item, workspace, profile)
                require(not ABSOLUTE.search(projected), 'unaliased_absolute_path')
                used.add(pointer)
                return projected
            require(not ABSOLUTE.search(item), 'unapproved_absolute_path')
            return item
        require(pointer not in allowed | uri_allowed, 'pointer_not_string')
        if isinstance(item, list):
            return [walk(child, pointer + '/' + str(index)) for index, child in enumerate(item)]
        if isinstance(item, dict):
            result = {}
            for key, child in item.items():
                require(not SENSITIVE_KEY.fullmatch(key), 'sensitive_json_key')
                require(not ABSOLUTE.search(key), 'absolute_path_in_key')
                result[key] = walk(child, pointer + '/' + pointer_part(key))
            return result
        return item
    result = walk(value)
    require(used == allowed, 'unused_json_pointer')
    require(used_uri == uri_allowed, 'unused_uri_pointer')
    return result


def machine_leak(raw, workspace, profile, allow_frozen_invalid=False):
    text = raw.decode('utf-8', errors='replace')
    strings = [text]
    if raw.lstrip().startswith((b'{', b'[')):
        try:
            value = parse(raw)
        except (ValueError, UnicodeDecodeError):
            require(allow_frozen_invalid, 'invalid_json_evidence')
            value = None  # Caller already checked the exact frozen corpus pin.
        def collect(item):
            if isinstance(item, str) and not isinstance(item, Number):
                strings.append(item)
            elif isinstance(item, dict):
                strings.extend(item.keys())
                for child in item.values(): collect(child)
            elif isinstance(item, list):
                for child in item: collect(child)
        collect(value)
    for base in (workspace, profile):
        for variant in {str(base), base.as_posix(), str(base).replace('\\', '\\\\')}:
            require(not any(variant.casefold() in value.casefold() for value in strings), 'machine_path_leak')
    require(not SECRET_TEXT.search(text), 'sensitive_material')


def scientific_location(source, public):
    def permitted(value):
        parts = PurePosixPath(value).parts
        return 'inputs' in parts or PurePosixPath(value).name.startswith('payload.')
    browser_payload = r'browser/(?:restart-)?(?:xes-csv\.payload\.csv|csv-xes\.payload\.xes|json-pnml\.payload\.pnml|pnml-json\.payload\.json|rich-allowed\.payload\.csv)'
    return (permitted(source) and permitted(public)) or (re.fullmatch(browser_payload, public) is not None and PurePosixPath(source).name == PurePosixPath(public).name)


def conversion_report_location(public):
    formats = (
        r'conversions/(?:reports/job-[0-9]{1,32}|cases/[A-Za-z0-9_-]{1,64}/(?:forward|inverse))/report\.json',
        r'conversion-boundaries/cases/(?:novel-csv|novel-xes|whitespace-default|whitespace-allow)/report\.json',
        r'browser/(?:restart-)?(?:xes-csv|csv-xes|json-pnml|pnml-json|rich-refused|rich-allowed)\.report\.json',
    )
    return any(re.fullmatch(pattern, public) is not None for pattern in formats)


def approved_frozen_input(raw, workspace, source, public):
    source_match = re.fullmatch(r'\.local/sprint21/root/conversion-(?:run|boundary)[0-9]{2}/inputs/([^/]+)', source)
    public_match = re.fullmatch(r'(?:conversions|conversion-boundaries)/inputs/([^/]+)', public)
    if not source_match or not public_match or source_match[1] != public_match[1]:
        return False
    corpus_raw = bounded(workspace / 'fixtures/conversions/corpus.json', MANIFEST_CAP, workspace)
    require(sha(corpus_raw) == FROZEN_CORPUS_SHA256, 'frozen_corpus_pin_mismatch')
    corpus = parse(corpus_raw)
    return any(case.get('input') == source_match[1] and case.get('input_sha256') == sha(raw)
               and int(case.get('input_bytes', '-1')) == len(raw) for case in corpus['cases'])


def validate_scientific_report(value):
    require(isinstance(value, dict), 'scientific_report_schema')
    require(isinstance(value.get('schema_version'), Number) and value['schema_version'] == '1', 'scientific_report_schema')
    require(value.get('method_sha256') == '49dc32d1f4219965ea57cc79caa9355974269fab989cc38d09173c8e734e619b', 'scientific_report_method')
    require((value.get('from'), value.get('to')) in (('xes', 'csv'), ('csv', 'xes'), ('petri-json', 'pnml'), ('pnml', 'petri-json')), 'scientific_report_direction')
    require(type(value.get('input_sha256')) is str and re.fullmatch('[0-9a-f]{64}', value['input_sha256']) is not None, 'scientific_report_input')
    def bounded_number(item):
        return isinstance(item, Number) and re.fullmatch('[0-9]+', item) is not None and int(item) <= 20 * 1024 * 1024
    require(bounded_number(value.get('input_bytes')) and type(value.get('allow_metadata_loss')) is bool, 'scientific_report_input')
    require(type(value.get('reason')) is str and 0 < len(value['reason']) <= 128, 'scientific_report_reason')
    if value.get('status') == 'converted':
        require(type(value.get('target_sha256')) is str and re.fullmatch('[0-9a-f]{64}', value['target_sha256']) is not None and bounded_number(value.get('target_bytes')), 'scientific_report_target')
        extension = {'petri-json': 'json', 'pnml': 'pnml', 'xes': 'xes', 'csv': 'csv'}[value['to']]
        require(value.get('payload_file') == 'payload.' + extension and isinstance(value.get('evidence'), dict), 'scientific_report_target')
    else:
        require(value.get('status') in ('refused', 'loss_refused', 'inconclusive') and all(value.get(key) is None for key in ('target_sha256', 'target_bytes', 'payload_file')), 'scientific_report_refusal')


def project(workspace, manifest, output, profile=None):
    started = time.monotonic()
    workspace = Path(os.path.abspath(workspace))
    profile = Path(os.path.abspath(Path.home() if profile is None else profile))
    output = Path(os.path.abspath(output))
    chain(workspace, workspace)
    require(workspace.is_dir(), 'trusted_workspace_directory_required')
    # Profile is used only as an alias prefix. No profile file is read or
    # traversed. The entire newly written output must remain in the workspace.
    require(inside(workspace, output) and output != workspace, 'output_outside_workspace')
    chain(output.parent, workspace)
    require(not output.exists() and not output.is_symlink(), 'fresh_output_required')
    manifest = Path(os.path.abspath(manifest))
    require(inside(workspace, manifest), 'manifest_outside_workspace')
    raw_manifest = bounded(manifest, MANIFEST_CAP, workspace)
    document = parse(raw_manifest)
    require(isinstance(document, dict) and set(document) == {'schema_version', 'entries'} and isinstance(document['schema_version'], Number) and document['schema_version'] == '1', 'manifest_schema')
    entries = document['entries']
    require(isinstance(entries, list) and len(entries) <= MAX_ENTRIES, 'entry_cap')
    staged = []
    inventory = []
    public_names = set()
    source_names = set()
    source_total = public_total = 0
    for entry in entries:
        require(time.monotonic() - started <= MAX_SECONDS, 'projection_deadline')
        require(isinstance(entry, dict) and set(entry) <= {'source', 'sha256', 'public_path', 'mode', 'json_pointers', 'uri_pointers', 'opaque_scientific', 'reason'}, 'entry_schema')
        require({'source', 'sha256', 'public_path', 'mode'} <= set(entry), 'entry_schema')
        source_name, public_name, mode = entry['source'], entry['public_path'], entry['mode']
        source = contained(workspace, source_name)
        relative(public_name)
        require(public_name.casefold() != 'projection-manifest.json', 'reserved_public_name')
        require(source_name.casefold() not in source_names and public_name.casefold() not in public_names, 'duplicate_entry')
        source_names.add(source_name.casefold()); public_names.add(public_name.casefold())
        require(mode in ('bytes', 'json_paths', 'omit'), 'entry_mode')
        require(isinstance(entry['sha256'], str) and re.fullmatch('[0-9a-fA-F]{64}', entry['sha256']), 'source_pin_required')
        raw = bounded(source, boundary=workspace)
        source_total += len(raw)
        require(source_total <= MAX_TOTAL, 'source_total_cap')
        require(sha(raw) == entry['sha256'].lower(), 'source_hash_mismatch')
        item = {'source': 'workspace:/' + source_name, 'public_path': public_name, 'mode': mode,
                'original_sha256': sha(raw), 'original_bytes': len(raw), 'json_pointers': [], 'uri_pointers': [],
                'numeric_tokens_sha256_before': None, 'numeric_tokens_sha256_after': None}
        if mode == 'omit':
            reason = entry.get('reason')
            require(isinstance(reason, str) and 0 < len(reason) <= 512 and not ABSOLUTE.search(reason) and not SECRET_TEXT.search(reason), 'omission_reason_required')
            require(not entry.get('json_pointers') and not entry.get('uri_pointers') and not entry.get('opaque_scientific'), 'omission_options')
            item['reason'] = reason
            item['public_sha256'] = None
            item['public_bytes'] = 0
            inventory.append(item)
            staged.append((source, sha(raw), None, None))
            continue
        require(not SENSITIVE_NAME.search(source_name) and not SENSITIVE_NAME.search(public_name), 'sensitive_filename')
        opaque = entry.get('opaque_scientific', False)
        require(type(opaque) is bool, 'opaque_flag')
        pointers = entry.get('json_pointers', [])
        require(isinstance(pointers, list) and all(pointer_valid(p) for p in pointers) and len(set(pointers)) == len(pointers), 'json_pointers')
        uri_pointers = entry.get('uri_pointers', [])
        require(isinstance(uri_pointers, list) and all(pointer_valid(p) for p in uri_pointers) and len(set(uri_pointers)) == len(uri_pointers), 'uri_pointers')
        require(not (set(pointers) & set(uri_pointers)), 'conflicting_pointer_types')
        require(not opaque or not uri_pointers, 'opaque_cannot_have_uri_pointers')
        require(not SECRET_TEXT.search(raw.decode('utf-8', errors='replace')), 'sensitive_material')
        before_numbers = after_numbers = None
        frozen_invalid = False
        if mode == 'json_paths':
            require(not opaque, 'json_cannot_be_opaque')
            value = parse(raw)
            before_numbers = numeric_tokens(value)
            projected = transform(value, set(pointers), workspace, profile, set(uri_pointers))
            after_numbers = numeric_tokens(projected)
            require(before_numbers == after_numbers, 'numeric_tokens_changed')
            public = (emit(projected) + '\n').encode('utf-8')
        else:
            require(not pointers, 'bytes_cannot_have_pointers')
            if opaque:
                if conversion_report_location(public_name):
                    validate_scientific_report(parse(raw))
                else:
                    require(scientific_location(source_name, public_name), 'opaque_scientific_location')
            # Even opaque input/payload JSON cannot export credentials or auth
            # snapshots; path/scientific-string rewriting is never permitted.
            if raw.lstrip().startswith((b'{', b'[')):
                try:
                    value = parse(raw)
                except (ValueError, UnicodeDecodeError):
                    # The sole exception is an exact immutable negative input
                    # pinned by the pre-existing, independently frozen corpus.
                    require(opaque and approved_frozen_input(raw, workspace, source_name, public_name), 'unapproved_malformed_scientific_input')
                    value = None
                    frozen_invalid = True
                def secret_keys(item):
                    if isinstance(item, dict):
                        require(not any(SENSITIVE_KEY.fullmatch(k) for k in item), 'sensitive_json_key')
                        for child in item.values(): secret_keys(child)
                    elif isinstance(item, list):
                        for child in item: secret_keys(child)
                    elif isinstance(item, str) and not isinstance(item, Number):
                        require(not SECRET_TEXT.search(item), 'sensitive_material')
                secret_keys(value)
                if not opaque:
                    transform(value, set(), workspace, profile, set(uri_pointers))
                before_numbers = after_numbers = None if frozen_invalid else numeric_tokens(value)
            else:
                require(not uri_pointers, 'uri_requires_json')
            public = raw
        require(len(public) <= MAX_FILE, 'public_file_cap')
        # Opaque means scientific bytes stay exact, never that machine paths or
        # credentials may be disclosed. This check also inspects decoded JSON.
        machine_leak(public, workspace, profile, allow_frozen_invalid=frozen_invalid)
        public_total += len(public)
        require(public_total <= MAX_TOTAL, 'public_total_cap')
        item.update({'public_sha256': sha(public), 'public_bytes': len(public),
                     'json_pointers': pointers, 'uri_pointers': uri_pointers, 'opaque_scientific': opaque,
                     'frozen_negative_input_corpus_sha256': FROZEN_CORPUS_SHA256 if frozen_invalid else None,
                     'numeric_tokens_sha256_before': before_numbers, 'numeric_tokens_sha256_after': after_numbers})
        inventory.append(item)
        staged.append((source, sha(raw), public_name, public))
    # Re-read pinned originals after all transformations, before any publication.
    for source, original, _, _ in staged:
        require(time.monotonic() - started <= MAX_SECONDS, 'projection_deadline')
        require(sha(bounded(source, boundary=workspace)) == original, 'source_changed')
    require(sha(bounded(manifest, MANIFEST_CAP, workspace)) == sha(raw_manifest), 'manifest_changed')
    report = {'schema_version': 1, 'manifest_sha256': sha(raw_manifest), 'source_bytes': source_total,
              'public_bytes': public_total, 'entries': inventory,
              'native_capture_hash_policy': 'Original native stdout/stderr hashes remain original; no descriptor rebinding.'}
    report_bytes = (json.dumps(report, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    require(len(report_bytes) <= MAX_FILE and public_total + len(report_bytes) <= MAX_TOTAL, 'projection_manifest_cap')
    machine_leak(report_bytes, workspace, profile)
    # NEW directory only, after complete validation. No old evidence is modified.
    output.mkdir()
    chain(output, workspace)
    for _, _, name, public in staged:
        require(time.monotonic() - started <= MAX_SECONDS, 'projection_deadline')
        if public is None:
            continue
        destination = contained(output, name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        chain(destination.parent, workspace)
        with destination.open('xb') as stream:
            stream.write(public)
        require(sha(bounded(destination, boundary=workspace)) == sha(public), 'public_write_mismatch')
    with (output / 'projection-manifest.json').open('xb') as stream:
        stream.write(report_bytes)
    for source, original, _, _ in staged:
        require(time.monotonic() - started <= MAX_SECONDS, 'projection_deadline')
        require(sha(bounded(source, boundary=workspace)) == original, 'source_changed')
    require(sha(bounded(manifest, MANIFEST_CAP, workspace)) == sha(raw_manifest), 'manifest_changed')
    require(time.monotonic() - started <= MAX_SECONDS, 'projection_deadline')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    report = project(args.workspace, args.manifest, args.output)
    print(json.dumps({'entries': len(report['entries']), 'source_bytes': report['source_bytes'], 'public_bytes': report['public_bytes']}))

if __name__ == '__main__':
    main()
