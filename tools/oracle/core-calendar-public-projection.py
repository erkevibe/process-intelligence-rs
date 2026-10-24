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
    parser = argparse.ArgumentParser(description='Source-only public field projection; never invoke an engine')
    parser.add_argument('--profile', choices=['calendar', 'filter-extended'], required=True)
    for key in ['java-index', 'rust-index', 'comparison']:
        parser.add_argument('--' + key, type=Path, required=True)
        parser.add_argument('--' + key + '-sha', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--local-root', action='append', default=[], help='Explicit additional ALIAS=ABSOLUTE_PATH, not a broad path scrub')
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    assert output.is_relative_to(workspace) and not output.exists(), 'fresh output inside checkout'
    profile = 'oracle-core-' + args.profile
    corpus_sha = {'calendar': 'f363e0952bcc8c153b7e269eba6535787a856a7e8693961fdaeaf6cc77de347e', 'filter-extended': '87d9c3731c66eedc0bf54fbb7a6652c8b20f507c9a1000f3d0ffeac46acfe5d3'}[args.profile]
    roots = [('workspace', workspace)]
    for declaration in args.local_root:
        name, text = declaration.split('=', 1)
        assert re.fullmatch('[a-z][a-z0-9-]{0,39}', name) and name != 'workspace'
        declared = Path(text)
        assert declared.is_absolute()
        roots.append((name, declared))
    output.mkdir(parents=True)
    products, originals, redactions = [], [], []

    def alias(path):
        path = Path(path).resolve()
        for name, root in roots:
            if path.is_relative_to(root):
                return name + '://' + path.relative_to(root).as_posix()
        raise ValueError('source path outside explicitly declared roots')

    def source(path, expected=None, cap=4 * 1024 * 1024):
        path = Path(path)
        assert path.stat().st_size <= cap
        raw = path.read_bytes()
        if expected:
            assert digest(raw) == expected.lower(), 'actual raw source SHA'
        originals.append({'source_alias': alias(path), 'sha256': digest(raw), 'bytes': len(raw)})
        return raw

    def sanitize(value, origin, pointer=''):
        if isinstance(value, dict):
            return {key: sanitize(child, origin, pointer + '/' + key) for key, child in value.items()}
        if isinstance(value, list):
            return [sanitize(child, origin, pointer + '/' + str(i)) for i, child in enumerate(value)]
        if not isinstance(value, str):
            return value
        transformed = value
        for name, root in sorted(roots, key=lambda row: len(str(row[1])), reverse=True):
            for text in [str(root), root.as_posix()]:
                at = transformed.lower().find(text.lower())
                if at >= 0:
                    transformed = transformed[:at] + name + '://' + transformed[at + len(text):].lstrip('\\/')
                    transformed = transformed.replace('\\', '/')
        assert not re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]', transformed) and not transformed.startswith('\\\\'), ('unmapped absolute path', origin, pointer)
        if transformed != value:
            redactions.append({'source_alias': origin, 'json_pointer': pointer, 'original_string_sha256': digest(value.encode('utf-8')), 'published_value': transformed})
        return transformed

    def write(relative, value, origin=None, raw_sha=None, preserved=None):
        raw = (encode(value) + '\n').encode('utf-8')
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as stream:
            stream.write(raw)
        products.append({'path': relative, 'sha256': digest(raw), 'bytes': len(raw), 'source_alias': origin, 'original_sha256': raw_sha, 'numeric_tokens_unchanged': preserved})
        return digest(raw)

    def projected_file(path, relative, expected):
        raw = source(path, expected)
        original = decode(raw)
        projected = sanitize(original, alias(path))
        assert number_tokens(original) == number_tokens(projected), 'every numeric lexical token retained'
        return original, projected, write(relative, projected, alias(path), digest(raw), True)

    corpus_path = workspace / 'fixtures' / profile / 'corpus.json'
    corpus_raw = source(corpus_path, corpus_sha)
    corpus = decode(corpus_raw)
    ids = [row['id'] for row in corpus['cases']]
    for side in ['java', 'rust']:
        index_path = getattr(args, side + '_index').resolve()
        raw = source(index_path, getattr(args, side + '_index_sha'))
        original = decode(raw)
        assert original['corpus_sha256'].lower() == corpus_sha
        assert [row['id'] for row in original['cases']] == ids, 'complete frozen order'
        published = sanitize(original, alias(index_path))
        for row, target, spec in zip(original['cases'], published['cases'], corpus['cases'], strict=True):
            assert row['input_sha256'].lower() == spec['sha256'].lower()
            for key in ['observation_path', 'native_record']:
                relative = Path(row[key])
                assert not relative.is_absolute() and '..' not in relative.parts and not re.match(r'^[A-Za-z]:', row[key]), 'portable index-relative paths'
            observation_path = index_path.parent / row['observation_path']
            observation, _, public_sha = projected_file(observation_path, side + '/' + row['id'] + '.json', row['observation_sha256'])
            assert observation['id'] == row['id'] and observation['input_sha256'].lower() == spec['sha256'].lower()
            native_path = index_path.parent / row['native_record']
            native, _, native_sha = projected_file(native_path, 'native/' + side + '-' + row['id'] + '.json', row['native_record_sha256'])
            assert native['native_exit'].token == '0' and native['stdout_complete'] is True and native['stderr_complete'] is True
            assert not any(native[key] for key in ['output_limit', 'capture_fault', 'drain_timeout'])
            stem = native_path.name.removesuffix('.process.json')
            for channel in ['stdout', 'stderr']:
                capture = native_path.parent / (stem + '.' + channel)
                captured = source(capture, native[channel + '_sha256'], cap=8 * 1024 * 1024)
                assert str(len(captured)) == native[channel + '_bytes_persisted'].token
            if side == 'rust':
                assert row['observation_sha256'].lower() == native['stdout_sha256'].lower(), 'original raw Rust JSON stdout remains bound'
            target.update(observation_path=side + '/' + row['id'] + '.json', observation_sha256=public_sha,
                          original_observation_sha256=row['observation_sha256'], native_record='native/' + side + '-' + row['id'] + '.json',
                          native_record_sha256=native_sha, original_native_record_sha256=row['native_record_sha256'])
        assert number_tokens(original) == number_tokens(published), 'index numeric tokens unchanged'
        published['original_index_sha256'] = digest(raw)
        write(side + '-index.json', published, alias(index_path), digest(raw), True)
    projected_file(args.comparison.resolve(), 'original-comparison.json', args.comparison_sha)
    for path in sorted(corpus_path.parent.glob('*.json')):
        raw = source(path)
        relative = 'fixtures/' + profile + '/' + path.name
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(raw)
        products.append({'path': relative, 'sha256': digest(raw), 'bytes': len(raw), 'source_alias': alias(path), 'original_sha256': digest(raw), 'byte_identical_copy': True})
    text = '''SPRINT19 FINITE CORE REFERENCE FIELD PROJECTION

Only full observations of frozen OWN SYNTHETIC fixtures and verified native
process records are included. Raw native console streams are not published.
Native record stdout/stderr byte counts and hashes bind their private original
bytes. Rust observation JSON was originally exact stdout; normalized public
JSON retains every numeric lexical token, including i64 extrema and -0.0.
Original raw hashes and projected hashes are always recorded separately.
Only explicitly declared local roots are replaced with aliases; an unmapped
absolute path aborts generation. No source file, raw observation, numeric
value, frozen expected result, executable, dependency or guard is changed.

From the repository root, using pinned Node24 numeric-source JSON support:
node tools/oracle/compare-core-PROFILE.mjs PUBLIC/java-index.json PUBLIC/rust-index.json NEW-comparison.json
Replace PROFILE with calendar or filter-extended, PUBLIC with this directory.
Observation/native paths are relative to each index file's directory. Compare
derived fields with original-comparison.json; index/observation SHA provenance
changes are explicit. Unexpected exceptions, failed hypotheses and diagnostic
semantic differences remain observations. Calendar main duration and secondary
rounding API outcomes are separate. Actual offsets are checked against frozen
UTC boundaries rather than inferred from the observed tzdb version.

This is not a standalone native environment or complete Core/R5 parity claim.
Java requires the separately retained canonical S16 build, all real pinned
runtime files, and pinned JDK11. Native replay requires a newly reviewed
workspace/configuration/Job/resource/deadline binding; no S18/S19 fixed expiry
is removed or bypassed here. No upstream binary or source payload is published.
'''
    path = output / 'README.txt'
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(text)
    products.append({'path': 'README.txt', 'sha256': digest(path.read_bytes()), 'bytes': path.stat().st_size})
    for item in products:
        text = (output / item['path']).read_text(encoding='utf-8-sig')
        assert not re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]|\\\\Users\\', text), item['path']
    write('projection-manifest.json', {'schema_version': 1, 'status': 'FINITE_NUMERIC_LEXEME_PRESERVING_PUBLIC_FIELD_PROJECTION',
          'profile': args.profile, 'corpus_sha256': corpus_sha, 'source_sha256': digest(Path(__file__).read_bytes()),
          'original_inputs': originals, 'products': products.copy(), 'redactions': redactions,
          'explicit_local_root_aliases': [name for name, _ in roots], 'no_engine_or_native_process_started': True,
          'no_original_input_modified': True, 'no_whole_R5_or_Core_parity_claim': True})
    print(json.dumps({'output': str(output), 'files': len(products), 'manifest_sha256': digest((output / 'projection-manifest.json').read_bytes())}))


if __name__ == '__main__':
    main()
