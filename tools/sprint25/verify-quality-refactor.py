"""Check a mechanical evaluator move against historical and fresh evidence.

No reference bundle is rewritten or relabelled. Historical reference metric
witnesses are reused only after exact case/input and structural graph checks;
the independent auditor recomputes the fresh paths, costs and rational scores.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def need(value, reason):
    if not value:
        raise ValueError(reason)


def raw(path):
    path = Path(path)
    need(path.is_file() and not path.is_symlink(), 'regular_input_required')
    with path.open('rb') as stream:
        data = stream.read(16 * 1024 * 1024 + 1)
    need(len(data) <= 16 * 1024 * 1024, 'input_byte_limit')
    return data


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load(path):
    return decode(raw(path))


def unique(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def decode(data):
    def nonfinite(_):
        raise ValueError('nonfinite_json_number')
    return json.loads(data, object_pairs_hook=unique, parse_constant=nonfinite)


def same(left, right):
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(same(left[key], right[key]) for key in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(same(a, b) for a, b in zip(left, right))
    return left == right


def import_tool(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def semantic_case(value, fitness_limit=None):
    # Equal-cost alignment routes and visited-state counts are nondeterministic
    # even across executions of the unchanged historical binary. BOTH routes
    # are independently replayed/optimality-checked below, never blindly omitted.
    if isinstance(value, dict):
        if type(value.get('limits')) is dict and 'fitness' in value['limits']:
            fitness_limit = value['limits']['fitness']
            need(type(fitness_limit) is int and 0 < fitness_limit <= 100000,
                 'fitness_limit_type_or_bound')
        if value.keys() == {'cost', 'moves', 'states_visited'}:
            need(type(value['cost']) is int and value['cost'] >= 0 and
                 type(value['states_visited']) is int and value['states_visited'] >= 0 and
                 type(value['moves']) is list, 'alignment_field_types')
            need(fitness_limit is not None and value['states_visited'] <= fitness_limit,
                 'alignment_visited_budget')
            for move in value['moves']:
                need(type(move) is dict and len(move) == 1, 'alignment_move_shape')
                kind, data = next(iter(move.items()))
                need(kind in ('ModelMove', 'SyncMove', 'LogMove') and type(data) is dict,
                     'alignment_move_kind')
                keys = ({'transition'} if kind == 'ModelMove' else
                        {'trace_event_index'} if kind == 'LogMove' else
                        {'transition', 'trace_event_index'})
                need(data.keys() == keys, 'alignment_move_keys')
                if 'transition' in data:
                    need(type(data['transition']) is str, 'alignment_transition_type')
                if 'trace_event_index' in data:
                    need(type(data['trace_event_index']) is int and
                         data['trace_event_index'] >= 0, 'alignment_index_type')
            return {'cost': value['cost'], 'route_requires_independent_optimality_check': True}
        return {key: semantic_case(item, fitness_limit) for key, item in value.items()
                if key != 'net_sha256'}
    if isinstance(value, list):
        return [semantic_case(item, fitness_limit) for item in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'before-prepared', 'after', 'after-prepared',
                 'reference', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    need(__debug__, 'assertions_required_by_independent_auditor')
    before, after, reference = load(args.before), load(args.after), load(args.reference)
    old_bundle = load(args.before_prepared / 'bundle.json')
    new_bundle = load(args.after_prepared / 'bundle.json')
    for result, bundle, directory in ((before, old_bundle, args.before_prepared),
                                      (after, new_bundle, args.after_prepared)):
        need(result['bundle_sha256'] == digest(raw(directory / 'bundle.json')),
             'actual_bundle_binding')
        need(result['sources'] == bundle['sources'], 'actual_source_binding')
        need(result['corpus_sha256'] == bundle['corpus_sha256'], 'corpus_binding')
    need(before['corpus_sha256'] == after['corpus_sha256'] ==
         reference['corpus_sha256'], 'same_frozen_corpus')
    need(reference['bundle_sha256'] == before['bundle_sha256'], 'original_reference_binding')
    need(same(semantic_case(before['cases']), semantic_case(after['cases'])),
         'case_or_numeric_status_witness_changed')
    need(before['scope'] == after['scope'] and before['phase'] == after['phase'],
         'scope_or_phase_changed')
    need(set(old_bundle['artifacts']) == set(new_bundle['artifacts']), 'artifact_coverage')
    for identity in old_bundle['artifacts']:
        old = old_bundle['artifacts'][identity]['prepared']
        new = new_bundle['artifacts'][identity]['prepared']
        need(old['status'] == new['status'], 'artifact_status_changed')
        if old['status'] != 'net_saved':
            need(same(old, new), 'refusal_changed')
            continue
        for directory, record in ((args.before_prepared, old),
                                  (args.after_prepared, new)):
            name = record['net_file']
            need(Path(name).name == name and ':' not in name and '\\' not in name,
                 'net_basename')
            need(digest(raw(directory / 'nets' / name)) == record['net_sha256'],
                 'net_bytes_binding')
        need(same(load(args.before_prepared / 'nets' / old['net_file']),
                  load(args.after_prepared / 'nets' / new['net_file'])),
             'net_structure_changed')
    root = Path(__file__).resolve().parents[2]
    audit = import_tool(root / 'tools/oracle/audit-quality-evidence.py', 'quality_audit')
    conservation = import_tool(root / 'tools/oracle/validate-quality-net-graph.py',
                               'quality_conservation')
    refs = {(row['id'], row['artifact_id']): row for row in reference['cases']}
    previous = {(case['id'], row['artifact_id']): (case, row)
                for case in before['cases'] for row in case['measurements']}
    need(len(refs) == len(reference['cases']), 'duplicate_reference')
    seen, checks, groups = set(), [], 0
    for case in after['cases']:
        for measurement in case['measurements']:
            key = (case['id'], measurement['artifact_id'])
            need(key not in seen and key in refs, 'reference_coverage')
            seen.add(key)
            result = measurement['result']
            if 'groups' not in result:
                checks.append({'id': key[0], 'artifact': key[1],
                               'status': result['status'], 'reason': result.get('reason')})
                continue
            record = new_bundle['artifacts'][key[1]]['prepared']
            net_bytes = raw(args.after_prepared / 'nets' / record['net_file'])
            need(digest(net_bytes) == result['graph']['net_sha256'], 'fresh_graph_binding')
            conservation.validate(net_bytes, result['graph'])
            fresh_groups, ref_groups = result['groups'], refs[key]['groups']
            need(same({row['group']: row['input'] for row in fresh_groups},
                      {row['group']: row['input'] for row in ref_groups}), 'reference_inputs')
            measured = audit.verify(result['graph'], decode(net_bytes), fresh_groups,
                                    ref_groups, case['limits'])
            old_case, old_measurement = previous[key]
            old_result = old_measurement['result']
            old_record = old_bundle['artifacts'][key[1]]['prepared']
            old_bytes = raw(args.before_prepared / 'nets' / old_record['net_file'])
            need(digest(old_bytes) == old_result['graph']['net_sha256'] ==
                 refs[key]['net_sha256'], 'original_graph_reference_binding')
            conservation.validate(old_bytes, old_result['graph'])
            audit.verify(old_result['graph'], decode(old_bytes), old_result['groups'],
                         ref_groups, old_case['limits'])
            groups += len(fresh_groups)
            checks.append({'id': key[0], 'artifact': key[1], 'groups': measured})
    need(seen == set(refs), 'complete_reference_coverage')
    report = {'status': 'SHARED_QUALITY_TYPED_SEMANTIC_PARITY_AND_INDEPENDENT_AUDIT_PASS',
              'before_sha256': digest(raw(args.before)),
              'after_sha256': digest(raw(args.after)),
              'historical_reference_sha256': digest(raw(args.reference)),
              'before_bundle_sha256': before['bundle_sha256'],
              'after_bundle_sha256': after['bundle_sha256'],
              'case_rows': len(after['cases']), 'artifact_rows': len(checks),
              'groups': groups, 'checks': checks,
              'scope': 'Exact typed complete case/numeric/status parity except bound net digests '
                       'and equal-cost alignment routes/visited counts. Both original and fresh '
                       'nets/graphs and alignment routes receive independent conservation, '
                       'optimal path/cost/rational audits. '
                       'Historical reference is not a fresh upstream execution or rebound bundle.'}
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(report, stream, indent=2)
        stream.write('\n')
    print(json.dumps({key: report[key] for key in ('status', 'case_rows', 'artifact_rows', 'groups')}))


if __name__ == '__main__':
    main()
