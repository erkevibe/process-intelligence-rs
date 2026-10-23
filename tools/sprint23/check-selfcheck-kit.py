"""Finite isolated ZIP self-check kit validation; no subprocess or network."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import sys
import time
import zipfile

PINS = {
    'tools/sprint23/audit-compact.py': '048A57750159B49D20E3CCABB02ACB1A7C4320A1C676DAB1B91291CF7114B802',
    'tools/sprint23/decode-report.py': '88E279F7B901D4F82F0D291E7832C76186F42550BFD16E67D1338E41A3F1608F',
    'tools/oracle/audit-conversion-evidence.py': 'C3CF6D5B5B5B0A4067C29175C4857964B81B766A84D1ED5C029AD49ED929BA3A',
}
FIXTURE_PINS = {
    'source.xes': '6BE15ABCC35C4BDF755F27307C93B0B5E4E5F90C7D715FCC4B57DC07A503516F',
    'default.json': '4E3194BF41C2217C1C992BEDA53B64D5FAD01A84CC739D30C4919D03C333813F',
    'compact.json': '1705D74DA362D9E15E31664AE3AD70441423F056572DB94A74F044FBD0368CC0',
    'payload.csv': 'F14031CC8FCDF5119AFFAF1C2490D54B779A0929754DEE6DDF8D6280971E2905',
}
CODEC = '620468860F91B64AD21F64427E97EAFDCB3D50506236CA38315485B1C29004D4'


def sha(raw):
    return hashlib.sha256(raw).hexdigest().upper()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('kit', type=Path); p.add_argument('kit_sha')
    p.add_argument('output', type=Path, help='existing empty protected private directory')
    p.add_argument('--doc-sha', required=True)
    p.add_argument('--workspace', type=Path, required=True)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--default-report', type=Path, required=True)
    p.add_argument('--compact-report', type=Path, required=True)
    p.add_argument('--payload', type=Path, required=True)
    args = p.parse_args(); started = time.monotonic()
    workspace = args.workspace.absolute()
    def need(ok, why):
        if not ok:
            raise ValueError(why)
        if time.monotonic()-started >= 45:
            raise ValueError('kit_check_deadline')
    def safe(path):
        path = path.absolute()
        need(path.is_relative_to(workspace) and '..' not in path.parts, 'workspace_boundary')
        cursor = workspace
        for part in (None, *path.relative_to(workspace).parts):
            if part is not None:
                cursor /= part
            st = cursor.lstat()
            need(not cursor.is_symlink() and not getattr(st, 'st_file_attributes', 0)&1024, 'no_reparse')
        return path
    def read(path, cap):
        path = safe(path)
        need(path.is_file() and path.stat().st_size <= cap, 'file_cap')
        with path.open('rb') as stream:
            raw = stream.read(cap+1)
        need(len(raw) <= cap, 'read_cap')
        return raw
    out = safe(args.output)
    need(out.is_dir() and not any(out.iterdir()), 'fresh_private_output')
    need(all(re.fullmatch('[0-9A-F]{64}', h) for h in (args.kit_sha, args.doc_sha)), 'hash_format')
    kit_raw = read(args.kit, 128*1024); need(sha(kit_raw) == args.kit_sha, 'kit_pin')
    pins = dict(PINS); pins['docs/SELF_CHECK_RU.md'] = args.doc_sha
    wanted = set(pins)|{'SHA256SUMS'}
    extracted = out/'kit'; extracted.mkdir()
    import io
    with zipfile.ZipFile(io.BytesIO(kit_raw)) as archive:
        entries = archive.infolist()
        need(len(entries) == 5 and len({e.filename.casefold() for e in entries}) == 5
             and {e.filename for e in entries} == wanted, 'exact_five_members')
        total = 0; data = {}
        for entry in entries:
            need(not entry.is_dir() and not stat.S_ISLNK(entry.external_attr>>16)
                 and not entry.flag_bits&1 and entry.file_size <= 128*1024, 'regular_bounded_member')
            total += entry.file_size; need(total <= 256*1024, 'expanded_cap')
            with archive.open(entry) as stream:
                raw = stream.read(128*1024+1)
            need(len(raw) == entry.file_size, 'exact_member_length_CRC')
            data[entry.filename] = raw
        rows = data['SHA256SUMS'].decode('ascii').splitlines(); sums = {}
        need(len(rows) == 4, 'four_hash_rows')
        for line in rows:
            match = re.fullmatch(r'([0-9A-Fa-f]{64})  (.+)', line)
            need(match is not None and match[2] not in sums, 'hash_row_shape')
            sums[match[2]] = match[1].upper()
        need(sums == pins, 'manifest_matches_independent_pins')
        for name, pin in pins.items():
            need(sha(data[name]) == pin, 'payload_hash')
        for name, raw in data.items():
            target = extracted/name; target.parent.mkdir(parents=True, exist_ok=True)
            safe(target.parent)
            with target.open('xb') as stream:
                stream.write(raw)
    fixture_dir = out/'fixtures'; fixture_dir.mkdir()
    for name, original in [('source.xes', args.source), ('default.json', args.default_report),
                           ('compact.json', args.compact_report), ('payload.csv', args.payload)]:
        raw = read(original, 64*1024); need(sha(raw) == FIXTURE_PINS[name], 'frozen_X01_pin')
        (fixture_dir/name).write_bytes(raw)
    def module(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
        return value
    audit = module('isolated_kit_audit', extracted/'tools/sprint23/audit-compact.py')
    decoder = module('isolated_kit_decoder', extracted/'tools/sprint23/decode-report.py')
    oracle_path = extracted/'tools/oracle/audit-conversion-evidence.py'
    oracle = module('isolated_kit_oracle', oracle_path)
    expected = {'traces': [{'name': 'case-α', 'events': [
        {'timestamp': '2026-10-22T01:02:03.123456789Z', 'lifecycle': 'start', 'activity': 'A, "β"'},
        {'timestamp': None, 'lifecycle': 'complete', 'activity': 'line\nbreak'}]}]}
    for name, kind in [('source.xes', 'xes'), ('payload.csv', 'csv')]:
        core, _ = oracle.core((fixture_dir/name).read_bytes(), kind)
        need(audit.typed_equal(core, expected), 'independent_manual_twoevent_core')
    def invoke(func, argv):
        previous = sys.argv
        try:
            sys.argv = argv; func()
        finally:
            sys.argv = previous
        need(True, 'deadline')
    def audit_args(report, output, source=None, payload=None):
        return ['kit-audit', str(fixture_dir/report), str(output), '--source',
                str(source or fixture_dir/'source.xes'), '--payload', str(payload or fixture_dir/'payload.csv'),
                '--oracle', str(oracle_path), '--codec-sha', CODEC, '--from', 'xes', '--to', 'csv']
    for report in ('default.json', 'compact.json'):
        invoke(audit.main, audit_args(report, out/(report+'.audit.json')))
    decoded = out/'decoded.json'
    decode_args = ['kit-decoder', str(fixture_dir/'compact.json'), str(decoded), '--codec-sha', CODEC]
    invoke(decoder.main, decode_args)
    _, _, exact = audit.decode_report((fixture_dir/'compact.json').read_bytes(), CODEC,
                                      allow_legacy=False, return_raw=True)
    need(decoded.read_bytes() == exact, 'exact_raw_decode')
    negatives = []
    for name, reason, source, payload in [
        ('changed_source', 'direct_source_binding', fixture_dir/'changed-source.xes', None),
        ('changed_payload', 'direct_payload_binding', None, fixture_dir/'changed-payload.csv')]:
        target = source or payload
        original = fixture_dir/('source.xes' if source else 'payload.csv')
        target.write_bytes(original.read_bytes()+b' ')
        observed = None
        try:
            invoke(audit.main, audit_args('compact.json', out/(name+'.json'), source, payload))
        except ValueError as error:
            observed = str(error)
        need(observed == reason, 'specific_'+name)
        negatives.append({'case': name, 'reason': observed, 'rejected': True})
    before = decoded.read_bytes(); observed = None
    try:
        invoke(decoder.main, decode_args)
    except ValueError as error:
        observed = str(error)
    need(observed == 'fresh_output' and decoded.read_bytes() == before, 'existing_output_no_overwrite')
    negatives.append({'case': 'existing_output', 'reason': observed, 'rejected': True})
    total_written = sum(f.stat().st_size for f in out.rglob('*') if f.is_file())
    need(total_written <= 1024*1024, 'private_output_cap')
    proof = {'status': 'ISOLATED_FIVE_MEMBER_SELFCHECK_KIT_PASS', 'kit_sha256': args.kit_sha,
             'legacy_and_compact_full_semantic_audits': 2, 'manual_events': 2,
             'exact_decoded_bytes_sha256': sha(exact), 'negative_controls': negatives,
             'kit_members': sorted(wanted), 'output_bytes': total_written,
             'limits': ['Only actual extracted kit code imported; source/payload are separate fixed fixtures.',
                        'Finite self-check tooling proof; no product conversion or generic authenticity signature.']}
    with (out/'kit-proof.json').open('x', encoding='utf-8') as stream:
        json.dump(proof, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
