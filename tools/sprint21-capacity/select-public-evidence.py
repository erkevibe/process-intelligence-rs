"""Build an explicit, pinned PRIVATE allowlist; never publish or mutate evidence.

Root and independent QA must review the resulting selection before projection.
No product, engine, compiler, network, or evidence-producing operation is run.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import time

HERE = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('s21_projection_policy', HERE.parent / 'sprint21/project-public-evidence.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
PHASES = ('compile10', 'compile11', 'compile12', 'compile13', 'compile14', 'compile15', 'capacity-postgres01', 'capacity-postgres02', 'capacity-postgres03', 'capacity-doc01', 'capacity-crash01', 'capacity-measure01', 'capacity-measure-resume01', 'capacity-browser-stand01', 'capacity-browser-stand02', 'capacity-guard-control01', 'capacity-postgres-recovery01', 'capacity-browser-audit01')
MAX_SCAN = 10000
FORBIDDEN = re.compile(r'(?i)(?:credentials|postgres-private|private-credentials|live-ready|(?:^|/)controls(?:/|$)|(?:^|/)(?:checkpoint-|app-[0-9]+-ready))')


def select(workspace, manifest):
    started = time.monotonic()
    workspace = Path(os.path.abspath(workspace))
    root = workspace / '.local/sprint21/root'
    manifest = Path(os.path.abspath(manifest))
    p.chain(root, workspace)
    p.require(p.inside(root, manifest) and not manifest.exists() and not manifest.is_symlink(), 'fresh_private_manifest_required')
    p.chain(manifest.parent, workspace)
    selections = [(name, name, 'phase') for name in PHASES]
    selections += [('capacity-browser-acceptance01', 'browser', 'browser'),
                   ('evidence-capacity-test03', 'capacity-test', 'complete'),
                   ('capacity-inputs02', 'inputs', 'recipe'),
                   ('capacity-cleanup01', 'cleanup', 'complete'),
                   ('evidence-capacity-test01', 'failed-capacity-test01', 'complete'),
                   ('evidence-capacity-test02', 'failed-capacity-test02', 'complete'),
                   ('failed-c01', 'failed-candidate-source', 'complete'),
                   ('failed-tcp-source01', 'failed-tcp-source', 'complete')]
    for name, _, _ in selections:
        p.require((root / name).is_dir(), 'required_final_phase_missing:' + name)
    entries = []
    total = scanned = 0
    names = set()

    def deadline():
        p.require(time.monotonic() - started <= 25, 'selection_deadline')

    def walk(directory):
        nonlocal scanned
        pending = [directory]
        while pending:
            current = pending.pop()
            p.chain(current, workspace)
            with os.scandir(current) as listing:
                children = sorted(list(listing), key=lambda e: e.name.casefold())
            for child in children:
                deadline()
                scanned += 1
                p.require(scanned <= MAX_SCAN, 'selection_scan_cap')
                item = Path(child.path)
                p.no_reparse(item)
                if child.is_dir(follow_symlinks=False):
                    pending.append(item)
                else:
                    p.require(child.is_file(follow_symlinks=False), 'regular_evidence_required')
                    yield item

    def json_policy(raw):
        value = p.parse(raw)
        paths, uris = [], []
        def visit(item, pointer=''):
            if isinstance(item, p.Number):
                return
            if isinstance(item, dict):
                for key, child in item.items():
                    p.require(not p.SENSITIVE_KEY.fullmatch(key), 'protected_json_material')
                    p.require(not p.ABSOLUTE.search(key), 'absolute_json_key')
                    visit(child, pointer + '/' + p.pointer_part(key))
            elif isinstance(item, list):
                for index, child in enumerate(item):
                    visit(child, pointer + '/' + str(index))
            elif isinstance(item, str) and p.ABSOLUTE.search(item):
                leaf = pointer.rsplit('/', 1)[-1]
                if leaf == 'program':
                    p.alias(item, workspace, Path.home().absolute())
                    paths.append(pointer)
                elif leaf in ('route', 'href') or '/links/' in pointer:
                    p.relative_uri(item, workspace, Path.home().absolute())
                    uris.append(pointer)
                else:
                    raise ValueError('unapproved_absolute_metadata')
        visit(value)
        projected = p.transform(value, set(paths), workspace, Path.home().absolute(), set(uris))
        p.machine_leak((p.emit(projected) + '\n').encode(), workspace, Path.home().absolute())
        return paths, uris

    def add(source, public, group):
        nonlocal total
        deadline()
        p.require(len(entries) < p.MAX_ENTRIES, 'selection_entry_cap')
        raw = p.bounded(source, boundary=workspace)
        total += len(raw)
        p.require(total <= p.MAX_TOTAL, 'selection_source_cap')
        source_name = source.relative_to(workspace).as_posix()
        p.relative(public)
        p.require(public.casefold() not in names, 'duplicate_public_selection')
        names.add(public.casefold())
        entry = dict(source=source_name, sha256=p.sha(raw), public_path=public, mode='bytes')
        reason = None
        local = source.relative_to(root).as_posix()
        if source.parent.name == 'capacity-crash01' and source.name in ('original-payload', 'original-report', 'recover-original-payload', 'recover-original-report', 'retried-payload', 'retried-report', 'verify-original-payload', 'verify-original-report', 'after-second-restart-payload', 'after-second-restart-report'):
            group = 'complete'
        if group == 'phase' and any(part.endswith('-http') for part in source.relative_to(root).parts[:-1]):
            group = 'complete'
        if FORBIDDEN.search(local):
            reason = 'Private credentials, controls, live readiness or intermediate checkpoint omitted'
        elif group == 'recipe' and source.name != 'manifest.json':
            reason = 'Deterministic input recipe and immutable hashes published; raw padded input omitted'
        elif group == 'phase' and not (source.name.endswith(('.process.json', '.start.json', '.stdout', '.stderr')) or source.name.endswith(('proof.json', '-stop.json', '-receipt.json')) or source.name in ('stand-closed.json', 'result.json', 'prospective-inputs-before-measurements.json', 'resume-attempt-context.json', 'memory-abi.json', 'control-results.json', 'transient-probe-window.json', 'synthetic-scan.json', 'actual-sprint-scan.json', 'recovery-preflight.json', 'precommit-native-crash.json', 'barrier-waiting.json', 'manual-audit.json') or source.name.endswith('memory-samples.json')):
            reason = 'Not in the explicit public phase-receipt selection; raw managed snapshots excluded'
        elif group == 'browser' and len(source.name.encode('utf-8')) > 255:
            reason = 'Raw long Unicode upload filename exceeds portable component byte cap; immutable corpus content and pinned metadata retained'
        elif group == 'browser' and source.suffix.lower() not in ('.json', '.png', '.csv', '.xes', '.pnml'):
            reason = 'Not a selected browser observation, download or screenshot'
        if reason is None:
            try:
                if p.conversion_report_location(public):
                    p.validate_scientific_report(p.parse(raw))
                    p.machine_leak(raw, workspace, Path.home().absolute())
                    entry['opaque_scientific'] = True
                elif p.scientific_location(source_name, public):
                    # Frozen negative inputs can intentionally be malformed.
                    # The projector rechecks their immutable bytes and privacy.
                    entry['opaque_scientific'] = True
                elif source.suffix.lower() == '.json':
                    paths, uris = json_policy(raw)
                    entry.update(mode='json_paths' if paths else 'bytes', json_pointers=paths, uri_pointers=uris)
                else:
                    if raw.lstrip().startswith((b'{', b'[')):
                        # SQL/native stdout may itself contain structured managed
                        # snapshots; never treat those as harmless text streams.
                        def private_snapshot(value):
                            if isinstance(value, dict):
                                p.require(not any(p.SENSITIVE_KEY.fullmatch(k) or k in ('pi_kv', 'pi_projects', 'pi_records') for k in value), 'protected_managed_snapshot')
                                for child in value.values(): private_snapshot(child)
                            elif isinstance(value, list):
                                for child in value: private_snapshot(child)
                        private_snapshot(p.parse(raw))
                    p.machine_leak(raw, workspace, Path.home().absolute())
            except (ValueError, UnicodeDecodeError, RecursionError):
                # No unknown strings/keys are relabelled or rewritten to make a
                # proof pass. The original identity remains in the omission list.
                reason = 'Privacy or explicit structural type policy rejected this raw metadata; original retained privately'
        if reason:
            entry = dict(source=source_name, sha256=p.sha(raw), public_path=public, mode='omit', reason=reason)
        entries.append(entry)

    for name, public_root, group in selections:
        for source in walk(root / name):
            add(source, public_root + '/' + source.relative_to(root / name).as_posix(), group)
    # Pin source bytes a second time. Never accept a changing or partial run.
    for entry in entries:
        deadline()
        p.require(p.sha(p.bounded(workspace / entry['source'], boundary=workspace)) == entry['sha256'], 'selection_source_changed')
    raw = (json.dumps({'schema_version': 1, 'entries': entries}, ensure_ascii=False, indent=2) + '\n').encode()
    p.require(len(raw) <= p.MANIFEST_CAP, 'selection_manifest_cap')
    p.chain(manifest.parent, workspace)
    with manifest.open('xb') as stream:
        stream.write(raw)
    deadline()
    return dict(entries=len(entries), omitted=sum(e['mode'] == 'omit' for e in entries), source_bytes=total,
                manifest_sha256=p.sha(raw))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--manifest', required=True)
    args = parser.parse_args()
    print(json.dumps(select(args.workspace, args.manifest)))

if __name__ == '__main__':
    main()
