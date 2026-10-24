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
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--public-prefix', default='evidence/sprint18/core-filter')
    parser.add_argument('--rust-index-sha', required=True)
    parser.add_argument('--comparison-sha', required=True)
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parents[2]
    service = workspace / '.local/sprint18/service/r5-filter01'
    rust_root = workspace / '.local/sprint18/root/filter-run01'
    output = args.output.resolve()
    assert output.is_relative_to(workspace) and not output.exists(), 'fresh workspace output required'
    prefix = args.public_prefix.replace('\\', '/').strip('/')
    assert prefix and '..' not in prefix.split('/') and not re.match(r'^[A-Za-z]:', prefix)
    output.mkdir(parents=True)
    originals, products, redactions = [], [], []

    def alias(path):
        path = Path(path)
        if not path.is_absolute():
            path = workspace / path
        return 'private-evidence://' + path.relative_to(workspace).as_posix().removeprefix('.local/')

    def source(path, expected=None):
        data = Path(path).read_bytes()
        assert len(data) <= 8 * 1024 * 1024, 'bounded source'
        if expected:
            assert digest(data) == expected.lower(), 'actual original source SHA'
        originals.append({'source_alias': alias(path), 'sha256': digest(data), 'bytes': len(data)})
        return data

    def write(relative, value, original_path=None, original_sha=None, token_preserved=None):
        data = (encode(value) + '\n').encode('utf-8')
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as target:
            target.write(data)
        products.append({'path': relative, 'sha256': digest(data), 'bytes': len(data),
                         'source_alias': alias(original_path) if original_path else None,
                         'original_sha256': original_sha, 'numeric_tokens_unchanged': token_preserved})
        return digest(data)

    def sanitize(value, origin, pointer=''):
        if isinstance(value, dict):
            result = {}
            for key, child in value.items():
                location = pointer + '/' + key
                if key == 'message' and '/exception/' in location and child is not None:
                    assert isinstance(child, str)
                    result[key] = None
                    result['message_sha256'] = digest(child.encode('utf-8'))
                    result['message_withheld'] = True
                    redactions.append({'source_alias': origin, 'json_pointer': location,
                                       'original_string_sha256': digest(child.encode('utf-8')),
                                       'transformation': 'exception_message_withheld_class_and_hash_retained'})
                else:
                    result[key] = sanitize(child, origin, location)
            return result
        if isinstance(value, list):
            return [sanitize(child, origin, pointer + '/' + str(index)) for index, child in enumerate(value)]
        if not isinstance(value, str):
            return value
        transformed = value
        for root_text in [str(workspace), workspace.as_posix()]:
            at = transformed.lower().find(root_text.lower())
            if at >= 0:
                transformed = transformed[:at] + 'workspace://' + transformed[at + len(root_text):].lstrip('\\/')
                transformed = transformed.replace('\\', '/')
        transformed = re.sub(r'\$\$Lambda\$\d+/0x[0-9a-fA-F]+', '$$Lambda$<ephemeral>', transformed)
        assert not re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]', transformed) and not transformed.startswith('\\\\'), ('unmapped path', origin, pointer)
        if transformed != value:
            redactions.append({'source_alias': origin, 'json_pointer': pointer,
                               'original_string_sha256': digest(value.encode('utf-8')),
                               'transformation': 'workspace_or_ephemeral_alias', 'published_value': transformed})
        return transformed

    def sanitized_file(path, relative, expected=None):
        raw = source(path, expected)
        original = decode(raw)
        result = sanitize(original, alias(path))
        assert number_tokens(original) == number_tokens(result), 'numeric lexical tokens preserved'
        hashed = write(relative, result, path, digest(raw), True)
        return original, result, hashed

    def resolved(path):
        path = Path(path)
        return path if path.is_absolute() else workspace / path

    corpus_path = workspace / 'fixtures/oracle-core-filter/corpus.json'
    corpus_sha = '0997acc2af6514c0d799181f78cfef217bddb375def14646f6864f8257cfce6c'
    corpus_raw = source(corpus_path, corpus_sha)
    corpus = decode(corpus_raw)
    java_path = service / 'reference-results.json'
    rust_path = rust_root / 'rust-results.json'
    java_raw = source(java_path, 'a6b1f7f644f90f99c841ed1121abf64b1bacdea556d564f630897f9ba5bc27fe')
    rust_raw = source(rust_path, args.rust_index_sha)
    java, rust = decode(java_raw), decode(rust_raw)
    assert java['corpus_sha256'].lower() == rust['corpus_sha256'].lower() == corpus_sha
    expected_ids = [row['id'] for row in corpus['cases']]
    for engine, index, raw, index_path in [('java', java, java_raw, java_path), ('rust', rust, rust_raw, rust_path)]:
        rows = index['cases']
        assert [row['id'] for row in rows] == expected_ids, 'all eight ordered cases'
        public_rows = []
        for row, spec in zip(rows, corpus['cases'], strict=True):
            path = resolved(row['observation_path'])
            if engine == 'rust':
                record_path = resolved(row['native_record'])
                record = decode(source(record_path, row['native_record_sha256']))
                assert record['stdout_sha256'].lower() == row['observation_sha256'].lower()
                assert path == record_path.with_name(record_path.name.removesuffix('.process.json') + '.stdout')
            observation, _, hashed = sanitized_file(path, engine + '/' + row['id'] + '.json', row['observation_sha256'])
            assert observation['id'] == row['id'] and observation['input_sha256'].lower() == spec['sha256'].lower()
            public_rows.append({'id': row['id'], 'observation_path': prefix + '/' + engine + '/' + row['id'] + '.json',
                                'observation_sha256': hashed, 'original_observation_sha256': row['observation_sha256'],
                                'input_sha256': spec['sha256']})
        write(engine + '-index.json', {'schema_version': 1, 'status': 'SANITIZED_ACTUAL_FINITE_CORE_FILTER_INDEX',
              'corpus_sha256': corpus_sha, 'original_index_sha256': digest(raw), 'cases': public_rows}, index_path, digest(raw))

    sanitized_file(workspace / '.local/sprint18/root/core-filter-comparison01.json', 'original-comparison.json', args.comparison_sha)
    native_rows = []
    for scope in [service, rust_root]:
        for path in sorted(scope.rglob('*.process.json')):
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
    assert len(native_rows) >= 27, 'Java compile/eight child+worker captures, eight Rust cases and outer command'
    write('native-summaries.json', {'schema_version': 1, 'records': native_rows,
          'console_streams_published': False, 'scope': 'Actual compile and finite Java/Rust runs only; summaries bind original full-stream bytes without publishing raw console text'})
    for name, expected in [('postcheck.json', '04b5a4aa13bfc35b388fbae3d50babaa232ebd0d36484ad3a06fa1698a527766'),
                           ('footprint.json', 'dc8a5f81bfa94f095d30c6d66826c3849da195187235aa759b861de7eeff0619')]:
        sanitized_file(service / name, name, expected)
    sanitized_file(service / 'observer-classes.json', 'observer-classes.json')
    sanitized_file(workspace / '.local/sprint18/service/r5-filter-feasibility01.json', 'original-class-source-provenance.json', '2ceb9ff85eef9bab675d133620969c0459dd1bb622eee8010cef70165e8caa94')
    canonical_path = workspace / '.local/sprint16/service/canonical-build-proof02.json'
    canonical_raw = source(canonical_path, '976db2b8712233abd6323286e0ad0ad0b0198d74147fc35596a18f13a8bedd83')
    canonical = decode(canonical_raw)
    write('canonical-inputs.json', sanitize({'schema_version': 1, 'core_commit': 'bbf24dfd43e72d6992392465f875a4367cbe792b',
          'canonical_build_proof_sha256': digest(canonical_raw), 'runtime_classpath_sha256': canonical['runtime_classpath_sha256'],
          'classpath_entries_in_order': canonical['classpath_entries'], 'runtime_files': canonical['runtime_files'],
          'jdk_archive_sha256': 'd5008f02174c1ad21c10407cbf104815cb390ec4c263d53946e8d0507d7a77f9',
          'no_upstream_source_or_binary_payload': True}, alias(canonical_path)))
    copy_paths = list(sorted((workspace / 'fixtures/oracle-core-filter').glob('*.json')))
    copy_paths.append(workspace / 'docs/R5_CASE_ACTIVITY_REFERENCE_CONTRACT.md')
    for path in copy_paths:
        raw = source(path, corpus['contract_sha256'] if path.name == 'R5_CASE_ACTIVITY_REFERENCE_CONTRACT.md' else None)
        relative = path.relative_to(workspace).as_posix()
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(raw)
        products.append({'path': relative, 'sha256': digest(raw), 'bytes': len(raw),
                         'source_alias': relative, 'original_sha256': digest(raw), 'byte_identical_copy': True})
    readme = '''GENUINE CORE CASE-ACTIVITY FILTER EVIDENCE — SPRINT 18

Six overlap cases compare the complete unchanged Apromore APMLogFilter API
against the existing Rust filters::apply. Two declared diagnostics preserve
empty-literal sentinel differences and original converter refusal for an empty
input. They are not equality passes. Full selected source identities, event
order, sparse ordinals, millisecond timestamps, lifecycle, warning metadata,
actual immutable indexes, and original source conservation are observed.
No extracted/reimplemented predicate, upstream edits, toy fallback, or whole
Core/R5/SplitMiner/miner-quality parity claim is made.

This dataset contains only OWN SYNTHETIC fixtures and sanitized observations.
All JSON numeric lexical tokens are preserved verbatim. Absolute workspace
paths become workspace:// aliases. Exception text is withheld while exception
classes and original UTF-8 message hashes remain. Original observation hashes
and published sanitized hashes are distinguished. Native stdout/stderr are
NOT published: summaries provide their original byte lengths, hashes, native
exits and EOF/capture flags. Those hashes do not recover omitted console text.
The single Java adapter/class set is pinned; no earlier public-import mixed
adapter carry is used to establish this independent filter result.

OFFLINE FIELD COMPARISON
From repository root with Node24 (numeric-source JSON reviver support):

node tools/oracle/compare-core-filter.mjs evidence/sprint18/core-filter/java-index.json evidence/sprint18/core-filter/rust-index.json NEW-comparison.json

The comparator binds sanitized observation/index hashes. Derived per-case
fields must equal original-comparison.json except each case's two observation
SHA fields; the top-level index hashes also intentionally change. A provenance
hash or aliased path is not a new algorithmic difference. Frozen fixtures and
the agreed contract are copied byte-identically here as backups; the comparator
uses fixtures/oracle-core-filter from the checkout.

NATIVE REPLAY DEPENDENCIES
The genuine Java oracle depends on the separately retained canonical S16
Apromore build at bbf24dfd43e72d6992392465f875a4367cbe792b, real runtime JARs,
and pinned JDK11. canonical-inputs.json and original-class-source-provenance.json
bind the real ordered classpath, class files and original source identity;
no upstream source, JAR, JDK or executable payload is published. Existing S18
runners have a fixed 2026-10-21T22:55:42Z expiry plus SID/path/resource guards.
Future native replay needs a NEW reviewed workspace/deadline/configuration
and dependencies. This is a portable field-comparison dataset, not a ready
public native bootstrap; no expired guard is bypassed.
'''
    target = output / 'README.txt'
    with target.open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(readme)
    products.append({'path': 'README.txt', 'sha256': digest(target.read_bytes()), 'bytes': target.stat().st_size})
    for product in products:
        text = (output / product['path']).read_text(encoding='utf-8-sig')
        assert not re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]|\\\\Users\\', text), product['path']
    manifest = {'schema_version': 1, 'status': 'SANITIZED_ACTUAL_CORE_FILTER_PUBLICATION_NOT_NATIVE_BOOTSTRAP',
                'transformation_source': 'tools/oracle/core-filter-public-evidence.py',
                'transformation_source_sha256': digest(Path(__file__).read_bytes()),
                'transformation': 'json_numeric_lexeme_preserving_string_redaction_v1', 'public_prefix': prefix,
                'java_cases': 8, 'rust_cases': 8, 'original_inputs': originals, 'redactions': redactions,
                'products': products.copy(), 'no_native_process_started': True, 'no_existing_input_modified': True,
                'no_whole_R5_or_Core_parity_claim': True}
    write('publication-manifest.json', manifest)
    print(json.dumps({'output': str(output), 'manifest_sha256': digest((output / 'publication-manifest.json').read_bytes()),
                      'java_cases': 8, 'rust_cases': 8, 'files': len(products)}))


if __name__ == '__main__':
    main()
