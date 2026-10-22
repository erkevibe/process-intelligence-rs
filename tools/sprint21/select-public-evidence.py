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
spec = importlib.util.spec_from_file_location('s21_projection_policy', HERE / 'project-public-evidence.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
PHASES = ('compile09', 'postgres08', 'historical04', 'crash02', 'browser-stand02')
MAX_SCAN = 10000
FORBIDDEN = re.compile(r'(?i)(?:credentials|postgres-private|private-credentials|live-ready|(?:^|/)controls(?:/|$)|(?:^|/)(?:checkpoint-|app-[0-9]+-ready))')


def select(workspace, manifest, converter_sha256, boundary_phase='conversion-boundary02'):
    started = time.monotonic()
    workspace = Path(os.path.abspath(workspace))
    root = workspace / '.local/sprint21/root'
    manifest = Path(os.path.abspath(manifest))
    p.chain(root, workspace)
    p.require(p.inside(root, manifest) and not manifest.exists() and not manifest.is_symlink(), 'fresh_private_manifest_required')
    p.chain(manifest.parent, workspace)
    p.require(re.fullmatch(r'conversion-boundary[0-9]{2}', boundary_phase) is not None, 'explicit_boundary_phase_required')
    selections = [('conversion-run02', 'conversions', 'complete'),
                  (boundary_phase, 'conversion-boundaries', 'complete')]
    selections += [(name, name, 'phase') for name in PHASES]
    selections += [('browser-acceptance02', 'browser', 'browser')]
    for name, _, _ in selections:
        p.require((root / name).is_dir(), 'required_final_phase_missing:' + name)
    p.require(re.fullmatch('[0-9a-fA-F]{64}', converter_sha256) is not None, 'expected_converter_pin_required')
    index = p.parse(p.bounded(root / 'conversion-run02/index.json', boundary=workspace))
    p.require(index.get('converter_sha256', '').lower() == converter_sha256.lower(), 'final_converter_pin_mismatch')
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
        if source.name == 'converter.process.json':
            capture = p.parse(raw)
            p.require(capture.get('program_sha256', '').lower() == converter_sha256.lower(), 'captured_converter_pin_mismatch')
        total += len(raw)
        p.require(total <= p.MAX_TOTAL, 'selection_source_cap')
        source_name = source.relative_to(workspace).as_posix()
        p.relative(public)
        p.require(public.casefold() not in names, 'duplicate_public_selection')
        names.add(public.casefold())
        entry = dict(source=source_name, sha256=p.sha(raw), public_path=public, mode='bytes')
        reason = None
        local = source.relative_to(root).as_posix()
        if FORBIDDEN.search(local):
            reason = 'Private credentials, controls, live readiness or intermediate checkpoint omitted'
        elif group == 'phase' and not (source.name.endswith(('.process.json', '.start.json', '.stdout', '.stderr')) or source.name.endswith(('proof.json', '-stop.json', '-receipt.json')) or source.name == 'stand-closed.json'):
            reason = 'Not in the explicit public phase-receipt selection; raw managed snapshots excluded'
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
                manifest_sha256=p.sha(raw), boundary_phase=boundary_phase)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--converter-sha256', required=True)
    parser.add_argument('--boundary-phase', default='conversion-boundary02')
    args = parser.parse_args()
    print(json.dumps(select(args.workspace, args.manifest, args.converter_sha256, args.boundary_phase)))

if __name__ == '__main__':
    main()
