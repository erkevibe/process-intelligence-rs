"""Publish sanitized synthetic observations; never execute services or copy upstream binaries.

JSON numeric tokens are kept as original lexical tokens, including signed i64 and
negative zero. Native console streams remain private; only verified summaries
and hashes are published. Every original/sanitized identity is distinguished.
"""
import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Number:
    token: str


def decode(data):
    return json.loads(data.decode('utf-8-sig'), parse_int=Number, parse_float=Number,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def encode(value, depth=0):
    if isinstance(value, Number):
        assert re.fullmatch(r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?', value.token)
        return value.token
    if isinstance(value, dict):
        if not value:
            return '{}'
        return '{\n' + ',\n'.join('  ' * (depth + 1) + json.dumps(key, ensure_ascii=False) + ': ' + encode(child, depth + 1)
                                  for key, child in value.items()) + '\n' + '  ' * depth + '}'
    if isinstance(value, list):
        if not value:
            return '[]'
        return '[\n' + ',\n'.join('  ' * (depth + 1) + encode(child, depth + 1) for child in value) + '\n' + '  ' * depth + ']'
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def number_tokens(value):
    if isinstance(value, Number):
        return [value.token]
    if isinstance(value, dict):
        return [token for child in value.values() for token in number_tokens(child)]
    if isinstance(value, list):
        return [token for child in value for token in number_tokens(child)]
    return []


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True, help='Fresh directory; no existing files are overwritten')
    parser.add_argument('--public-prefix', default='evidence/sprint18/public-service', help='Repository-relative destination used by portable indexes')
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parents[2]
    own = workspace / '.local/sprint18/service'
    output = args.output.resolve()
    assert output.is_relative_to(workspace) and not output.exists(), 'fresh output inside workspace required'
    prefix = args.public_prefix.replace('\\', '/').strip('/')
    assert prefix and '..' not in prefix.split('/') and not re.match(r'^[A-Za-z]:', prefix)
    output.mkdir(parents=True)
    original_inputs = []
    products = []
    redactions = []
    source_sha = digest(Path(__file__).read_bytes())

    def alias(path):
        path = Path(path)
        return 'private-evidence://' + path.relative_to(workspace).as_posix().removeprefix('.local/')

    def source(path, expected=None):
        path = Path(path)
        data = path.read_bytes()
        actual = digest(data)
        if expected:
            assert actual == expected.lower(), 'original input identity'
        original_inputs.append({'source_alias': alias(path), 'sha256': actual, 'bytes': len(data)})
        return data

    def write(relative, value, origin=None, original_sha=None, numeric_tokens_unchanged=None):
        data = (encode(value) + '\n').encode('utf-8')
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as target:
            target.write(data)
        products.append({'path': relative, 'sha256': digest(data), 'bytes': len(data),
                         'source_alias': origin, 'original_sha256': original_sha,
                         'numeric_tokens_unchanged': numeric_tokens_unchanged})
        return digest(data)

    def sanitize(value, source_alias, pointer=''):
        if isinstance(value, dict):
            result = {}
            for key, child in value.items():
                location = pointer + '/' + key
                if key == 'message' and '/exception/' in location and child is not None:
                    assert isinstance(child, str)
                    result[key] = None
                    result['message_sha256'] = digest(child.encode('utf-8'))
                    result['message_withheld'] = True
                    redactions.append({'source_alias': source_alias, 'json_pointer': location,
                                       'original_string_sha256': digest(child.encode('utf-8')),
                                       'transformation': 'exception_message_withheld_class_and_hash_retained'})
                else:
                    result[key] = sanitize(child, source_alias, location)
            return result
        if isinstance(value, list):
            return [sanitize(child, source_alias, pointer + '/' + str(index)) for index, child in enumerate(value)]
        if not isinstance(value, str):
            return value
        transformed = value
        for root_text in [str(workspace), workspace.as_posix()]:
            at = transformed.lower().find(root_text.lower())
            if at >= 0:
                transformed = transformed[:at] + 'workspace://' + transformed[at + len(root_text):].lstrip('\\/')
                transformed = transformed.replace('\\', '/')
        transformed = re.sub(r'\$\$Lambda\$\d+/0x[0-9a-fA-F]+', '$$Lambda$<ephemeral>', transformed)
        # No unrecognized absolute Windows/UNC path is silently published.
        assert not re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]', transformed) and not transformed.startswith('\\\\'), ('unmapped absolute path', source_alias, pointer)
        if transformed != value:
            redactions.append({'source_alias': source_alias, 'json_pointer': pointer,
                               'original_string_sha256': digest(value.encode('utf-8')),
                               'transformation': 'workspace_path_or_ephemeral_lambda_alias', 'published_value': transformed})
        return transformed

    def sanitized_file(path, relative, expected=None):
        raw = source(path, expected)
        original = decode(raw)
        result = sanitize(original, alias(path))
        assert number_tokens(original) == number_tokens(result), 'numeric token preservation'
        hashed = write(relative, result, alias(path), digest(raw), True)
        return original, result, hashed

    reference_path = own / 'corpus02/reference-results.json'
    rust_path = own / 'rust-observers01/rust-results.json'
    reference_bytes = source(reference_path, '833e07a357d38ab745a64cde78581d09abd6f82bdd3cf3627648f058324f6817')
    rust_bytes = source(rust_path, '8e4b770e4a5a59e5c9dfd1769fcc9d22a8a549f5856a1ff6923ca59a675ffd8d')
    reference, rust = decode(reference_bytes), decode(rust_bytes)
    carry_path = own / 'corpus02/ten-case-carry.json'
    _, _, carry_sha = sanitized_file(carry_path, 'carry.json', '7dcf59d4aba5b454883b77f2367c98e6c69dfc501fa8eb50e1071905e9ef762a')
    java_rows = []
    for row in reference['cases']:
        path = Path(row['native']['path'] + '.json')
        _, _, published_sha = sanitized_file(path, 'java/' + row['id'] + '.json', row['observation_sha256'])
        java_rows.append({
            'id': row['id'], 'input_sha256': row['input_sha256'],
            'observation_sha256': published_sha, 'original_observation_sha256': row['observation_sha256'],
            'native': {'path': prefix + '/java/' + row['id'], 'private_capture_alias': alias(Path(row['native']['path']))},
            'adapter_generation': row['adapter_generation'],
            'frozen_manual_expected_checks': row['frozen_manual_expected_checks'],
            'pending_manual_expected_fields': row['pending_manual_expected_fields']})
    write('reference-index.json', {'schema_version': 1, 'status': 'SANITIZED_ACTUAL_PUBLIC_FINITE_REFERENCE_INDEX',
          'original_index_sha256': digest(reference_bytes), 'case_count': len(java_rows),
          'source_aware_carry': {'path': prefix + '/carry.json', 'sha256': carry_sha,
                                'original_sha256': reference['source_aware_carry']['sha256']},
          'all_frozen_checked_fields_match': reference['all_frozen_checked_fields_match'], 'cases': java_rows,
          'no_single_adapter_binary_claim': True}, alias(reference_path), digest(reference_bytes))
    rust_rows = []
    for row in rust['cases']:
        path = Path(row['path'])
        if not path.is_absolute():
            path = workspace / Path(str(path).replace('\\', '/'))
        _, _, published_sha = sanitized_file(path, 'rust/' + row['id'] + '.json', row['observation_sha256'])
        rust_rows.append({'id': row['id'], 'input_sha256': row['input_sha256'],
                          'path': prefix + '/rust/' + row['id'] + '.json', 'observation_sha256': published_sha,
                          'original_observation_sha256': row['observation_sha256'], 'program_sha256': row['program_sha256']})
    write('rust-index.json', {'schema_version': 1, 'status': 'SANITIZED_RETAINED_NATIVE_RUST_OBSERVATION_INDEX',
                            'original_index_sha256': digest(rust_bytes), 'case_count': len(rust_rows), 'cases': rust_rows}, alias(rust_path), digest(rust_bytes))

    native_rows = []
    for path in sorted(own.rglob('*.process.json')):
        raw = source(path)
        record = decode(raw)
        label = path.name.removesuffix('.process.json')
        for stream in ['stdout', 'stderr']:
            capture = path.parent / (label + '.' + stream)
            data = capture.read_bytes()
            assert digest(data) == record[stream + '_sha256'].lower()
            assert str(len(data)) == record[stream + '_bytes_persisted'].token
        keys = ['pid', 'native_creation_utc', 'started_utc', 'completed_utc', 'program_sha256', 'native_exit',
                'stdout_complete', 'stderr_complete', 'stdout_bytes_persisted', 'stderr_bytes_persisted',
                'stdout_sha256', 'stderr_sha256', 'output_limit', 'drain_timeout', 'capture_fault']
        native_rows.append({'source_alias': alias(path), 'original_record_sha256': digest(raw),
                            **{key: record[key] for key in keys if key in record}})
    write('native-summaries.json', {'schema_version': 1, 'status': 'VERIFIED_ALL_CURRENT_S18_SERVICE_NATIVE_SUMMARIES',
          'records': native_rows, 'console_streams_published': False,
          'scope': 'Includes successful, compiler-failed and observer-failed runs; exit/capture flags are observations, not blanket PASS'})
    sanitized_file(own / 'gate01/preflight-refusal01.json', 'preflight-refusal.json')
    write('observer-correction-ledger.json', {'schema_version': 1, 'events': [
        {'id': 'preworker-manifest-cap', 'kind': 'own_guard_preflight_refusal_no_native', 'evidence': 'preflight-refusal.json'},
        {'id': 'gate01-advisor-missing', 'kind': 'own_observer_not_applied', 'resolved_by': 'own_infrastructure_advisor_role', 'earlier_native_result_retained': True},
        {'id': 'gate02-ambiguous-role', 'kind': 'own_compiler_error', 'resolved_by': 'fully_qualified_spring_annotation', 'failed_native_result_retained': True},
        {'id': 'corpus01-empty-reload-observer-null', 'kind': 'own_observer_null_dereference_after_actual_service_returned_null',
         'resolved_by': 'nullable_observation_only_no_upstream_change', 'fresh_actual_case': 'java/all-filtered.json', 'failed_native_result_retained': True}],
        'limitations': ['No failed old case relabeled as successful', 'Frozen 11+1 source hypotheses never changed']})

    canonical = workspace / '.local/sprint16/service/canonical-build-proof02.json'
    canonical_bytes = source(canonical, '976db2b8712233abd6323286e0ad0ad0b0198d74147fc35596a18f13a8bedd83')
    build = decode(canonical_bytes)
    write('canonical-inputs.json', sanitize({'schema_version': 1, 'core_commit': 'bbf24dfd43e72d6992392465f875a4367cbe792b',
          'canonical_build_proof_sha256': digest(canonical_bytes), 'original_source_files': build['original_source_files'],
          'service_class_sha256': build['service_class_sha256'], 'runtime_classpath_sha256': build['runtime_classpath_sha256'],
          'classpath_entries_in_order': build['classpath_entries'], 'runtime_files': build['runtime_files'],
          'jdk_archive_sha256': 'd5008f02174c1ad21c10407cbf104815cb390ec4c263d53946e8d0507d7a77f9',
          'gradle_7_1_1_distribution_sha256': 'bf8b869948901d422e9bb7d1fa61da6a6e19411baa7ad6ee929073df85d6365d',
          'no_upstream_binary_or_source_payload_published': True}, alias(canonical)))
    sanitized_file(own / 'postcheck01.json', 'postcheck.json', 'ab1133a6f73412dfe567df9be5d772119e0171c4a631df4bddc5e47f0cb38c3a')
    fixture_rows = []
    for path in sorted((workspace / 'fixtures/oracle-public-service').rglob('*')):
        if not path.is_file():
            continue
        raw = source(path)
        relative = path.relative_to(workspace).as_posix()
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(raw)
        products.append({'path': relative, 'sha256': digest(raw), 'bytes': len(raw), 'source_alias': relative,
                         'original_sha256': digest(raw), 'byte_identical_copy': True})
        fixture_rows.append({'repository_path': relative, 'sha256': digest(raw), 'bytes': len(raw)})
    write('fixture-inventory.json', {'schema_version': 1, 'own_synthetic_fixtures_only': True, 'files': fixture_rows})

    # Detect private drive/UNC paths in every output, including generated metadata.
    for item in products:
        text = (output / item['path']).read_text(encoding='utf-8-sig')
        assert not re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]|\\\\Users\\', text), item['path']
    instructions = '''PUBLIC SERVICE EVIDENCE — SPRINT 18

This folder contains full typed observations of OWN SYNTHETIC fixtures, not native
console logs, user data, upstream source, JARs, JDKs, or executable payloads.
Every signed integer and float numeric JSON token is retained verbatim by the
publication transform. This includes i64 extrema, values beyond 2^53 and -0.0.
Absolute workspace paths become workspace:// aliases; ephemeral lambda addresses
are aliased. Exception message text is withheld; original UTF-8 message SHA256 and
exception classes remain. Original observation hashes and sanitized file hashes
are distinct and recorded. Native stream byte counts/hashes/exits/EOF flags are
published; the original streams remain private. These hashes are provenance,
not a claim that omitted native streams can be independently recovered here.

To reproduce the FIELD COMPARISON, place this directory at
evidence/sprint18/public-service in a checkout containing the original frozen
fixtures/oracle-public-service and tools/oracle/compare-public-service.mjs.
Use Node 24 with JSON reviver numeric-source support, from the repository root:

node tools/oracle/compare-public-service.mjs --matrix evidence/sprint18/public-service/reference-index.json evidence/sprint18/public-service/rust-index.json NEW-comparison.json

The result will bind SANITIZED observation/index hashes rather than the private
original hashes. Public indexes retain original hashes separately. Compare full
typed fields and the explicit mismatch/null/rollback findings; do not treat new
index hashes or path aliases as an algorithmic difference. The copied fixtures
inside this folder are byte-identical backups of the repository fixtures.

NATIVE REPLAY IS NOT PROVIDED AS A READY PUBLIC ENVIRONMENT.
It depends on the separately built canonical Apromore core commit
bbf24dfd43e72d6992392465f875a4367cbe792b, all real runtime dependencies, pinned
JDK11 and Gradle7.1.1, plus the declared selective Spring/Hibernate/H2/FILE/cache
wiring. canonical-inputs.json records ordered classpath aliases and hashes;
it does not download or rebuild them. The public-service runners contain the
fixed S18 freeze 2026-10-21T22:55:42Z and private SID/path/resource controls.
Future native execution requires a NEW reviewed workspace, deadline, mechanism,
configuration and dependency binding; current private paths are not a portable
bootstrap. No expired guard is removed or bypassed by this publication tool.

SCOPE AND FINDINGS
Actual unchanged public importLog username/perspective=false path only, with
real reachable Spring transaction/JPA/H2/FILE/Ehcache/APMLog dependencies and
explicitly unwired unreachable services. No Portal/HTTP authentication,
production MySQL, perspective=true, complete service wiring, whole R2, or
enterprise parity claim. Ten observations retain the earlier non-null adapter
identity; two use a null-capable observer. carry.json proves the exact own-source
repair and unchanged compiled classes; there is no single-binary batch claim.
DB rollback/unique-constraint failure leaves observed file/cache side effects.
The all-filtered log persists but returns null after cache/database reopen.
Default XLog name trailing whitespace changes after storage reparse. Raw
Rust4PM metadata and application preview admission are separate profiles.
Frozen failed hypotheses and actual nulls remain failures/nulls, never fabricated
empty models or silently normalized equality.
'''
    readme = output / 'README.txt'
    with readme.open('x', encoding='utf-8', newline='\n') as target:
        target.write(instructions)
    products.append({'path': 'README.txt', 'sha256': digest(readme.read_bytes()), 'bytes': readme.stat().st_size})
    manifest = {'schema_version': 1, 'status': 'SANITIZED_ACTUAL_EVIDENCE_PUBLICATION_PREPARED_NOT_NATIVE_REPLAY',
                'transformation': 'json_numeric_lexeme_preserving_string_redaction_v1',
                'transformation_source': 'tools/oracle/public-service-public-evidence.py', 'transformation_source_sha256': source_sha,
                'public_prefix': prefix, 'java_cases': len(java_rows), 'rust_inputs': len(rust_rows),
                'original_inputs': original_inputs, 'redactions': redactions, 'products': products,
                'workspace_alias': 'workspace:// means the original private checkout root; its absolute value is never published',
                'no_native_process_started': True, 'no_existing_input_modified': True}
    write('publication-manifest.json', manifest)
    print(json.dumps({'output': str(output), 'manifest_sha256': digest((output / 'publication-manifest.json').read_bytes()),
                      'java_cases': len(java_rows), 'rust_inputs': len(rust_rows), 'files': len(products)}))


if __name__ == '__main__':
    main()
