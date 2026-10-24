"""Replay the exact archived shared evaluator evidence and corruption controls."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shared_quality_audit',
                                             ROOT / 'tools/sprint25/verify-quality-refactor.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def extract(package, output):
    manifest = audit.load(package / 'manifest.json')
    audit.need(type(manifest['schema_version']) is int and manifest['schema_version'] == 1 and
               type(manifest['expanded_bytes']) is int and
               type(manifest['tool_sources']) is dict and set(manifest['tool_sources']) == {
                   'tools/sprint25/verify-quality-refactor.py',
                   'tools/oracle/audit-quality-evidence.py',
                   'tools/oracle/validate-quality-net-graph.py'}, 'manifest_contract')
    for relative, expected in manifest['tool_sources'].items():
        audit.need(audit.digest(audit.raw(ROOT / relative)) == expected, 'exact_auditor_source')
    archive = package / 'quality-evidence.zip'
    with archive.open('rb') as stream:
        data = stream.read(32 * 1024 * 1024 + 1)
    audit.need(len(data) <= 32 * 1024 * 1024 and
               hashlib.sha256(data).hexdigest() == manifest['archive_sha256'], 'archive_binding')
    files = manifest['files']
    audit.need(type(files) is list and 1 <= len(files) <= 256, 'archive_member_limit')
    names, folded, total = set(), set(), 0
    for row in files:
        name = row['path']
        path = PurePosixPath(name)
        audit.need(type(name) is str and path.as_posix() == name and not path.is_absolute()
                   and all(part not in ('.', '..') for part in path.parts)
                   and ':' not in name and '\\' not in name and name not in names
                   and name.casefold() not in folded, 'portable_unique_member')
        reserved = {'con', 'prn', 'aux', 'nul'} | {
            prefix + str(number) for prefix in ('com', 'lpt') for number in range(1, 10)}
        audit.need(all(not part.endswith((' ', '.')) and
                       part.split('.')[0].casefold() not in reserved and
                       not any(ord(char) < 32 for char in part) for part in path.parts),
                   'windows_portable_member')
        audit.need(name in ('metrics.json', 'audit.json') or name.startswith('prepared/'),
                   'declared_evidence_scope')
        audit.need(type(row['bytes']) is int and 0 <= row['bytes'] <= 16 * 1024 * 1024,
                   'member_byte_limit')
        names.add(name)
        folded.add(name.casefold())
        total += row['bytes']
    audit.need(total == manifest['expanded_bytes'] and total <= 32 * 1024 * 1024,
               'expanded_byte_limit')
    output = output.absolute()
    audit.need(output.is_relative_to(ROOT / '.local'), 'owned_replay_scope')
    current = ROOT
    for part in output.relative_to(ROOT).parts:
        current /= part
        if current.exists() or current.is_symlink():
            info = current.lstat()
            audit.need(not current.is_symlink() and
                       not getattr(info, 'st_file_attributes', 0) & 1024, 'reparse_output')
    audit.need(not output.exists(), 'fresh_replay_output')
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        audit.need(len(entries) == len(files) and {entry.filename for entry in entries} == names,
                   'complete_archive_set')
        # Validate every member before creating the destination.
        for row in files:
            entry = source.getinfo(row['path'])
            mode = stat.S_IFMT(entry.external_attr >> 16)
            audit.need(mode in (0, stat.S_IFREG) and not entry.is_dir() and
                       entry.file_size == row['bytes'], 'regular_exact_member')
            with source.open(entry) as stream:
                raw = stream.read(16 * 1024 * 1024 + 1)
            audit.need(len(raw) == row['bytes'] and audit.digest(raw) == row['sha256'],
                       'member_identity')
        output.mkdir(parents=True)
        for row in files:
            target = output.joinpath(*PurePosixPath(row['path']).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(row['path']) as stream, target.open('xb') as dest:
                raw = stream.read(16 * 1024 * 1024 + 1)
                audit.need(len(raw) == row['bytes'] and audit.digest(raw) == row['sha256'],
                           'member_identity_on_write')
                dest.write(raw)
    return output


def invoke(work, metrics, name):
    previous = sys.argv
    sys.argv = ['verify-quality-refactor',
                '--before', str(ROOT / 'evidence/sprint19/bpmn-quality/rust-metrics.json'),
                '--before-prepared', str(ROOT / 'evidence/sprint19/bpmn-quality/prepared'),
                '--after', str(metrics), '--after-prepared', str(work / 'prepared'),
                '--reference', str(ROOT / 'evidence/sprint19/bpmn-quality/reference-metrics.json'),
                '--output', str(work / (name + '-audit.json'))]
    try:
        audit.main()
    finally:
        sys.argv = previous


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=ROOT / 'evidence/sprint25/quality')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    work = extract(args.package, args.output)
    invoke(work, work / 'metrics.json', 'positive')
    source = audit.raw(work / 'metrics.json')
    original = audit.decode(source)
    for name in ('boolean-cost', 'numeric-score', 'same-cost-invalid-route', 'duplicate-key'):
        value = copy.deepcopy(original)
        metric = value['cases'][0]['measurements'][0]['result']['groups'][0]['metrics']['fitness']
        if name == 'boolean-cost':
            audit.need(metric['integer_components']['weighted_total_cost'] == 0, 'control_input')
            metric['integer_components']['weighted_total_cost'] = False
        elif name == 'numeric-score':
            audit.need(metric['fitness']['log_fitness'] == 1.0, 'control_input')
            metric['fitness']['log_fitness'] = 0.5
        elif name == 'same-cost-invalid-route':
            metric['empty_alignment']['moves'][0]['ModelMove']['transition'] = (
                '00000000-0000-0000-0000-ffffffffffff')
        raw = (source.rstrip()[:-1] + b',"schema_version":1}' if name == 'duplicate-key'
               else json.dumps(value, indent=2).encode())
        path = work / (name + '.json')
        with path.open('xb') as stream:
            stream.write(raw)
        caught = None
        try:
            invoke(work, path, name)
        except (ValueError, AssertionError) as error:
            caught = error
        if name == 'same-cost-invalid-route':
            correct = (type(caught) is AssertionError and caught.args ==
                       ((0, '00000000-0000-0000-0000-ffffffffffff'),))
        else:
            expected = ('duplicate_json_key' if name == 'duplicate-key' else
                        'case_or_numeric_status_witness_changed')
            correct = type(caught) is ValueError and caught.args == (expected,)
        audit.need(correct and not (work / (name + '-audit.json')).exists(),
                   'negative_wrong_first_cause_' + name)
        print(json.dumps({'control': name, 'status': 'EXPECTED_REFUSAL'}))
    print(json.dumps({'status': 'SHARED_QUALITY_ARCHIVE_REPLAY_AND_FOUR_CONTROLS_PASS',
                      'fresh_upstream_run_claimed': False}))


if __name__ == '__main__':
    main()
