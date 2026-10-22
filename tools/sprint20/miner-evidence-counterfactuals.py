"""Pure cloned-evidence negative controls. Never starts native benchmark jobs."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

CAP = 100 * 1024 * 1024
EXPECTED_SOURCE = 'def4962492a2338cf9d1b68d037eadfbfdaff27a755e0fef1c7f5004d9ec1b93'
COMPLETE = 'COMPLETE_FROZEN_BENCHMARK_AND_CONDITIONAL_HISTORICAL_CARRY'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=True, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def descriptor(path):
    return {'file': path.name, 'bytes': path.stat().st_size, 'sha256': sha(path)}


def inventory(root):
    rows = {}
    for path in root.rglob('*'):
        if path.is_symlink() or (hasattr(path.stat(), 'st_file_attributes') and path.stat().st_file_attributes & 1024):
            raise ValueError('reparse_refused')
        if path.is_file():
            rows[path.relative_to(root).as_posix()] = {'bytes': path.stat().st_size, 'sha256': sha(path)}
    return rows


def trial_paths(base, row):
    def child(name):
        path = base / name
        if not path.resolve().is_relative_to(base.resolve()):
            raise ValueError('clone_path_escape')
        return path
    result = child(row['result_directory'])
    return result, child(row['native_record_path']), child(row['live_counters_path'])


def rebind(base, row, summary, observations=None):
    """Rebind descriptors through ledger, summary, ready, console and live/index.

    Observation values in summary can intentionally remain inconsistent in the
    timing control; every surrounding SHA is nevertheless recomputed.
    """
    result, native_path, live_path = trial_paths(base, row)
    ledger_path = result / 'iteration-ledger.jsonl'
    ledger = [json.loads(line) for line in ledger_path.read_text(encoding='utf-8').splitlines()]
    for event in ledger:
        if event['event'] == 'call_completed':
            event['observation'] = descriptor(result / (event['call_id'] + '.json'))
    ledger_path.write_text(''.join(json.dumps(v, ensure_ascii=True, separators=(',', ':')) + '\n' for v in ledger), encoding='utf-8')
    if observations:
        summary['iterations'] = [observations.get(v['call_id'], v) for v in summary['iterations']]
    summary['artifacts'] = [descriptor(result / v['file']) for v in summary['artifacts']]
    summary['ledger'] = descriptor(ledger_path)
    summary_path = result / 'summary.json'
    save(summary_path, summary)
    ready_path = result / 'terminal-ready.json'
    ready = load(ready_path)
    ready.update(summary=descriptor(summary_path), ledger=descriptor(ledger_path))
    save(ready_path, ready)
    terminal = row['terminal']
    terminal.update(summary=descriptor(summary_path), ledger=descriptor(ledger_path), terminal_ready=descriptor(ready_path))
    native = load(native_path)
    stdout = native_path.with_name(native_path.name.removesuffix('.process.json') + '.stdout')
    lines = stdout.read_text(encoding='utf-8').splitlines(keepends=True)
    replaced = 0
    for i, line in enumerate(lines):
        if line.startswith('S20_PROTOCOL ') and json.loads(line[13:])['phase'] == 'TERMINAL_READY':
            lines[i] = 'S20_PROTOCOL ' + json.dumps(terminal, separators=(',', ':')) + '\n'
            replaced += 1
    if replaced != 1:
        raise ValueError('exact_terminal_protocol_required')
    stdout.write_text(''.join(lines), encoding='utf-8', newline='')
    native.update(stdout_sha256=sha(stdout), stdout_bytes_persisted=stdout.stat().st_size)
    save(native_path, native)
    live = load(live_path)
    live['terminal'] = terminal
    save(live_path, live)


def mutate(kind, base, index):
    row = index['processes'][1 if kind == 'reused_identity' else 0]
    result, native_path, live_path = trial_paths(base, row)
    summary = load(result / 'summary.json')
    if kind == 'reused_identity':
        _, first_native, _ = trial_paths(base, index['processes'][0])
        first, native = load(first_native), load(native_path)
        native.update(pid=first['pid'], native_creation_utc=first['native_creation_utc'])
        save(native_path, native)
        return 'fresh_jvm_identity_reused'
    if kind == 'engine_summary_inconsistency':
        observation = result / (summary['iterations'][0]['call_id'] + '.json')
        value = load(observation)
        value['engine_time_nanos'] += 1
        save(observation, value)
        rebind(base, row, summary)
        return 'summary_full_observation_binding'
    if kind == 'parser_identity':
        summary['parser_identity']['sha256'] = '0' * 64
        rebind(base, row, summary)
        return 'observed_class_binding:parser_identity'
    if kind in ('memory_order', 'cpu_order'):
        live = load(live_path)
        if kind == 'memory_order':
            live['process_memory']['current_working_set_bytes'] = live['process_memory']['peak_working_set_bytes'] + 1
        else:
            live['process_cpu']['user_cpu_100ns'] = row['process_cpu_after_exit']['user_cpu_100ns'] + 1
        save(live_path, live)
        return 'memory_highwater_order' if kind == 'memory_order' else 'cpu_monotonicity'
    if kind == 'tick_order':
        row['exit_dispatch_ticks'] = row['terminal_ready_ticks'] - 1
        return 'controller_time_order'
    if kind == 'semantic_edge':
        observation_path = result / (summary['iterations'][0]['call_id'] + '.json')
        observation = load(observation_path)
        bpmn_path = result / observation['bpmn']['file']
        root = ET.fromstring(bpmn_path.read_bytes())
        flows = [e for e in root.iter() if e.tag.endswith('}sequenceFlow')]
        if not flows:
            raise ValueError('actual_flow_required')
        flow = flows[0]
        old = flow.attrib['targetRef']
        candidates = [e.attrib['id'] for e in root.iter() if e.tag.endswith('}endEvent') and e.attrib.get('id') != old]
        if not candidates:
            candidates = [flow.attrib['sourceRef']]
        flow.set('targetRef', candidates[0])
        bpmn_path.write_bytes(ET.tostring(root, encoding='utf-8', xml_declaration=True))
        observation['bpmn'] = descriptor(bpmn_path)
        save(observation_path, observation)
        rebind(base, row, summary, {observation['call_id']: observation})
        return 'full_semantic_bijection_failed'
    raise ValueError('unknown_control')


def public_mutation(kind, root, index_path, map_path, aggregate):
    """Alter publication bytes, never silently rewrite native origin authority."""
    index = load(index_path)
    row = index['processes'][0]
    result, native_path, live_path = trial_paths(index_path.parent, row)
    mapping = load(map_path)
    by_path = {r['path']: r for r in mapping['files']}

    def refresh(path, numeric=False):
        entry = by_path[path.relative_to(root).as_posix()]
        entry.update(published_bytes=path.stat().st_size, published_sha256=sha(path))
        if numeric and path.suffix == '.json':
            # Deliberately defeat the shallow numeric digest gate, so the
            # independent native-memory/class predicate must reject the change.
            entry['scientific_numeric_lexeme_sha256'] = aggregate.numeric_lexeme_digest(path.read_bytes())

    if kind == 'public_raw_stdout':
        raw = native_path.with_name(native_path.name.removesuffix('.process.json') + '.raw.stdout')
        with raw.open('ab') as stream:
            stream.write(b'\nSYNTHETIC_TD_TAMPER_NOT_NATIVE\n')
        refresh(raw)
        expected = 'stream_length'
    elif kind == 'public_origin_link':
        raw = native_path.with_name(native_path.name.removesuffix('.process.json') + '.raw.stdout')
        by_path[raw.relative_to(root).as_posix()]['source_path'] = raw.relative_to(root).as_posix()
        expected = 'raw_capture_source_mapping'
    elif kind == 'public_memory_counter':
        live = load(live_path)
        live['process_memory']['current_working_set_bytes'] = live['process_memory']['peak_working_set_bytes'] + 1
        save(live_path, live)
        refresh(live_path, numeric=True)
        expected = 'memory_highwater_order'
    elif kind == 'public_environment_class':
        environment = index_path.parent / index['environment_path']
        value = load(environment)
        value['class_identities']['parser_identity']['sha256'] = '0' * 64
        save(environment, value)
        refresh(environment, numeric=True)
        index['environment_sha256'] = sha(environment)
        save(index_path, index)
        refresh(index_path, numeric=True)
        expected = 'actual_prepublication_class_pin:parser_identity'
    else:
        raise ValueError('unknown_public_control')
    save(map_path, mapping)
    # The outer root manifest has its own content identity. Rebind modified
    # payload rows and totals too, avoiding a trivial stale outer manifest.
    manifest_path = root / 'manifest.json'
    if manifest_path.exists():
        manifest = load(manifest_path)
        for entry in manifest['files']:
            path = root / entry['path']
            entry.update(bytes=path.stat().st_size, sha256=sha(path))
        manifest['file_count'] = len(manifest['files'])
        manifest['total_bytes'] = sum(r['bytes'] for r in manifest['files'])
        save(manifest_path, manifest)
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('corpus', 'index', 'output-directory'):
        parser.add_argument('--' + key, required=True, type=Path)
    parser.add_argument('--public-projection', type=Path,
                        help='Explicit whole-public-root map; selects four additional projection controls, private mode retains the original seven')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1] / 'oracle/audit-miner-benchmark-evidence.py'
    if sha(source) != EXPECTED_SOURCE:
        raise ValueError('aggregate_source_pin')
    spec = importlib.util.spec_from_file_location('td_frozen_benchmark_aggregate', source)
    aggregate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(aggregate)
    original = (args.public_projection.parent if args.public_projection else args.index.parent).resolve()
    output = args.output_directory.resolve()
    if output == original or output.is_relative_to(original) or original.is_relative_to(output):
        raise ValueError('disjoint_fresh_output_required')
    original_inventory = inventory(original)
    kinds = (['public_raw_stdout', 'public_origin_link', 'public_memory_counter', 'public_environment_class']
             if args.public_projection else
             ['reused_identity', 'engine_summary_inconsistency', 'parser_identity', 'memory_order', 'cpu_order', 'tick_order', 'semantic_edge'])
    cap = 512 * 1024 * 1024 if args.public_projection else CAP
    if sum(v['bytes'] for v in original_inventory.values()) * len(kinds) > cap * 4 // 5:
        raise ValueError('clone_preflight_eighty_percent_cap')
    output.mkdir(exist_ok=False)
    baseline_dir = output / 'baseline-semantics'
    baseline_dir.mkdir()
    baseline = aggregate.audit(args.corpus, args.index, baseline_dir, public_projection=args.public_projection)
    save(output / 'baseline-audit.json', baseline)
    if baseline['status'] != COMPLETE or baseline['errors']:
        raise ValueError('actual_complete_baseline_required')
    rows = []
    for kind in kinds:
        base = output / kind
        shutil.copytree(original, base, symlinks=False)
        index_path = base / args.index.resolve().relative_to(original)
        index = load(index_path)
        map_path = base / args.public_projection.resolve().relative_to(original) if args.public_projection else None
        if map_path:
            expected = public_mutation(kind, base, index_path, map_path, aggregate)
            index = load(index_path)
        else:
            expected = mutate(kind, base, index)
            save(index_path, index)
        modified = inventory(base)
        changed = [{'path': p, 'before': original_inventory.get(p), 'after': value} for p, value in modified.items() if original_inventory.get(p) != value]
        semantic_dir = output / (kind + '-semantics')
        semantic_dir.mkdir()
        report = aggregate.audit(args.corpus, index_path, semantic_dir, public_projection=map_path)
        save(output / (kind + '-audit.json'), report)
        reasons = [e['reason'] for e in report['errors']]
        passed = report['status'] != COMPLETE and expected in reasons
        rows.append({'control': kind, 'synthetic_cloned_evidence_not_native_invocation': True, 'expected_gate': expected, 'actual_reasons': reasons, 'passed': passed, 'original_index_sha256': sha(args.index), 'modified_index_sha256': sha(index_path), 'patched_files': changed, 'preserved_processes': len(index['processes']), 'preserved_scheduled_calls': sum(len(r['scheduled_calls']) for r in index['processes'])})
        save(output / 'checkpoint.json', {'controls': rows})
        if sum(v['bytes'] for v in inventory(output).values()) > cap:
            raise ValueError('total_output_cap')
        if not passed:
            raise ValueError('specific_negative_control_gate_not_reached:' + kind)
    if inventory(original) != original_inventory:
        raise ValueError('original_evidence_changed')
    status = 'PASS_FOUR_PROJECTED_PROVENANCE_NEGATIVE_CONTROLS' if args.public_projection else 'PASS_ALL_SEVEN_SCIENCE_SPECIFIC_NEGATIVE_CONTROLS'
    save(output / 'result.json', {'status': status, 'output_cap_bytes': cap, 'aggregate_sha256': sha(source), 'driver_sha256': sha(Path(__file__)), 'controls': rows, 'actual_native_invocations': 0, 'baseline_index_sha256': sha(args.index), 'original_evidence_unchanged': True})


if __name__ == '__main__':
    main()
