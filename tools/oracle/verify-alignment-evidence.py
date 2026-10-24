"""Offline stdlib verification of the finite Petri alignment evidence directory.

Checks original bytes, full executable paths, analytic tiny-net costs and weighted
fitness. Does not independently prove mined-net global optimality or broad quality.
"""
import argparse
from collections import Counter, deque
from decimal import Decimal
from fractions import Fraction
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import uuid

CORPUS_SHA = 'fab7e1952bf5fab56c210023cd6d8b13fa4e19874ed5762330c78bbda68ce075'
LIMIT = 8 * 1024 * 1024
TOLERANCE = Fraction(1, 10**12)
MANUAL_LANGUAGES = {'SEQ': [('A', 'B', 'C')],
                    'CHOICE': [('A', 'B', 'D'), ('A', 'C', 'D')],
                    'TAU': [('A', 'B')],
                    'AND': [('A', 'B', 'C', 'D'), ('A', 'C', 'B', 'D')]}


def check(ok, message):
    if not ok:
        raise ValueError(message)


def unique(pairs):
    out = {}
    for key, value in pairs:
        check(key not in out, 'duplicate_json_key')
        out[key] = value
    return out


def loads(data):
    return json.loads(data.decode('utf-8-sig'), parse_float=Decimal,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('nonfinite_json')),
                      object_pairs_hook=unique)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def no_link(path):
    for part in [path, *path.parents]:
        info = part.lstat()
        check(not stat.S_ISLNK(info.st_mode) and
              not getattr(info, 'st_file_attributes', 0) & 1024, 'reparse_or_symlink')


def read(path):
    no_link(path)
    check(path.is_file() and path.stat().st_size <= LIMIT, 'file_limit')
    data = path.read_bytes()
    check(len(data) <= LIMIT, 'file_grew')
    return data


def close(actual, expected, name):
    check(abs(Fraction(actual) - expected) <= TOLERANCE, name)


def edit_cost(log, model):
    # Alignments permit log/model cost1; a mismatch requires both, cost2.
    previous = list(range(len(model) + 1))
    for i, event in enumerate(log, 1):
        current = [i]
        for j, label in enumerate(model, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (0 if event == label else 2)))
        previous = current
    return previous[-1]


def ideal_cost(net_name, sequence):
    return min(edit_cost(sequence, word) for word in MANUAL_LANGUAGES[net_name])


def manual_net(spec):
    # Same publicly frozen symbolic identities; labels/arcs remain explicit.
    places = {name: str(uuid.UUID(int=i + 1)) for i, name in enumerate(spec['places'])}
    transitions = {name: str(uuid.UUID(int=i + 1001))
                   for i, name in enumerate(sorted(spec['transitions']))}
    arcs = []
    for source, target in spec['arcs']:
        if source in places:
            kind, ends = 'PlaceTransition', [places[source], transitions[target]]
        else:
            kind, ends = 'TransitionPlace', [transitions[source], places[target]]
        arcs.append({'from_to': {'type': kind, 'nodes': ends}, 'weight': 1})
    return {'places': {identity: {'id': identity} for identity in places.values()},
            'transitions': {identity: {'id': identity, 'label': spec['transitions'][name]}
                            for name, identity in transitions.items()},
            'arcs': arcs,
            'initial_marking': {places[name]: n for name, n in spec['initial'].items()},
            'final_markings': [{places[name]: n for name, n in spec['final'].items()}]}


def variants(rows):
    result = Counter()
    for row in rows:
        sequence = tuple(row['sequence'])
        frequency = row['frequency']
        check(isinstance(frequency, int) and not isinstance(frequency, bool) and 0 < frequency <= 64,
              'variant_frequency')
        check(len(sequence) <= 64 and all(isinstance(s, str) and 0 < len(s.encode()) <= 200 for s in sequence),
              'variant_sequence')
        result[sequence] += frequency
    check(0 < sum(result.values()) <= 64 and len(result) <= 32 and
          sum(len(seq) * count for seq, count in result.items()) <= 500, 'projection_limit')
    return result


def reference_fitness(rows, model_name):
    counts = variants(rows)
    empty = min(map(len, MANUAL_LANGUAGES[model_name]))
    total = sum(counts.values())
    cost = sum(freq * ideal_cost(model_name, seq) for seq, freq in counts.items())
    denominator = sum(freq * (len(seq) + empty) for seq, freq in counts.items())
    average = sum((freq * (1 - Fraction(ideal_cost(model_name, seq), len(seq) + empty))
                   for seq, freq in counts.items()), Fraction()) / total
    perfect = Fraction(sum(freq for seq, freq in counts.items() if ideal_cost(model_name, seq) == 0), total)
    return cost, denominator, 1 - Fraction(cost, denominator), average, perfect


def net_parts(net):
    places = tuple(sorted(net['places']))
    transitions = net['transitions']
    check(places and len(places) + len(transitions) <= 128 and len(net['arcs']) <= 256,
          'net_size')
    check(not set(places) & set(transitions), 'net_id_overlap')
    for identity, value in net['places'].items():
        check(value['id'] == identity, 'place_internal_id')
    for identity, value in transitions.items():
        check(value['id'] == identity, 'transition_internal_id')
    inputs = {identity: {} for identity in transitions}
    outputs = {identity: {} for identity in transitions}
    endpoints = set()
    for arc in net['arcs']:
        weight = arc['weight']
        check(isinstance(weight, int) and not isinstance(weight, bool) and 0 < weight <= 255,
              'net_arc_weight')
        source, target = arc['from_to']['nodes']
        check((source, target) not in endpoints, 'net_duplicate_arc')
        endpoints.add((source, target))
        if arc['from_to']['type'] == 'PlaceTransition':
            check(source in places and target in transitions, 'net_input_reference')
            inputs[target][source] = weight
        else:
            check(arc['from_to']['type'] == 'TransitionPlace' and
                  source in transitions and target in places, 'net_output_reference')
            outputs[source][target] = weight

    def marking(value):
        check(isinstance(value, dict) and set(value) <= set(places), 'net_marking')
        check(all(isinstance(n, int) and not isinstance(n, bool) and 0 <= n <= 255
                  for n in value.values()), 'net_marking_count')
        return tuple(value.get(p, 0) for p in places)

    check(isinstance(net['final_markings'], list) and len(net['final_markings']) == 1,
          'single_final_marking')
    return places, transitions, inputs, outputs, marking(net['initial_marking']), marking(net['final_markings'][0])


def fire(state, transition, places, inputs, outputs):
    marking = dict(zip(places, state))
    check(all(marking[p] >= n for p, n in inputs[transition].items()), 'disabled_transition_fired')
    for place, amount in inputs[transition].items():
        marking[place] -= amount
    for place, amount in outputs[transition].items():
        marking[place] += amount
    check(all(0 <= n <= 255 for n in marking.values()), 'token_bound')
    return tuple(marking[p] for p in places)


def reachable_admission(net):
    places, transitions, inputs, outputs, initial, final = net_parts(net)
    seen = {initial}
    queue = deque([initial])
    maximum = max(initial, default=0)
    while queue:
        state = queue.popleft()
        maximum = max(maximum, *state)
        for transition in transitions:
            if not all(state[places.index(p)] >= n for p, n in inputs[transition].items()):
                continue
            following = fire(state, transition, places, inputs, outputs)
            if following not in seen:
                check(len(seen) < 10000, 'independent_marking_budget_inconclusive')
                seen.add(following)
                queue.append(following)
    check(final in seen, 'final_unreachable')
    return len(seen), maximum


def replay(net, sequence, result):
    places, transitions, inputs, outputs, state, final = net_parts(net)
    position = 0
    cost = 0
    for move in result['moves']:
        check(isinstance(move, dict) and len(move) == 1, 'alignment_move_shape')
        kind, fields = next(iter(move.items()))
        if kind == 'LogMove':
            check(fields['trace_event_index'] == position and position < len(sequence), 'log_move_index')
            position += 1
            cost += 1
            continue
        check(kind in {'SyncMove', 'ModelMove'}, 'alignment_move_kind')
        identity = fields['transition']
        check(identity in transitions, 'alignment_transition_reference')
        label = transitions[identity]['label']
        if kind == 'SyncMove':
            check(fields['trace_event_index'] == position and position < len(sequence) and
                  label is not None and label == sequence[position], 'sync_label_index')
            position += 1
        else:
            cost += int(label is not None)
        state = fire(state, identity, places, inputs, outputs)
    check(position == len(sequence) and state == final, 'alignment_not_complete')
    check(cost == result['cost'] and 0 <= result['states_visited'] <= 100000,
          'alignment_cost_states')
    return cost


def validate_measurement(measurement, rows, net=None, manual_name=None):
    check(measurement['status'] == 'measured', 'required_measurement_inconclusive')
    counts = variants(rows)
    projected = measurement['projection']
    check(projected['act_to_index'] == {s: i for i, s in enumerate(projected['activities'])}, 'reverse_projection')
    projected_counts = Counter()
    for indexes, frequency in projected['traces']:
        projected_counts[tuple(projected['activities'][i] for i in indexes)] += frequency
    check(projected_counts == counts, 'full_projection_conservation')
    aligned = Counter()
    costs = {}
    empty = measurement['empty_alignment']
    if net is not None:
        replay(net, (), empty)
        states, maximum = reachable_admission(net)
        check(measurement['admission']['markings'] == states and
              measurement['admission']['max_tokens_per_place'] == maximum, 'independent_admission_counts')
    else:
        check(empty['cost'] == min(map(len, MANUAL_LANGUAGES[manual_name])), 'manual_empty_cost')
    for variant in measurement['alignments']:
        sequence = tuple(variant['activities'])
        frequency = variant['frequency']
        check(sequence not in costs and set(variant['result']) == {'Ok'}, 'variant_unique_success')
        result = variant['result']['Ok']
        cost = replay(net, sequence, result) if net is not None else ideal_cost(manual_name, sequence)
        check(cost == result['cost'], 'manual_optimal_cost')
        costs[sequence] = cost
        aligned[sequence] += frequency
    check(aligned == counts, 'all_variants_and_frequencies')
    total = sum(counts.values())
    weighted = sum(freq * costs[sequence] for sequence, freq in counts.items())
    denominator = sum(freq * (len(sequence) + empty['cost']) for sequence, freq in counts.items())
    log = 1 - Fraction(weighted, denominator) if denominator else Fraction(1)
    average = sum((freq * (1 - Fraction(costs[sequence], len(sequence) + empty['cost']))
                   if len(sequence) + empty['cost'] else Fraction(freq)
                   for sequence, freq in counts.items()), Fraction()) / total
    perfect = sum(freq for sequence, freq in counts.items() if costs[sequence] == 0)
    check(measurement['integer_check'] == {'weighted_total_cost': weighted, 'traces': total,
                                         'denominator': denominator, 'perfect_traces': perfect}, 'integer_aggregate')
    fitness = measurement['fitness']
    check(fitness['total_costs'] == weighted, 'fitness_total_cost')
    close(fitness['log_fitness'], log, 'weighted_log_fitness')
    close(fitness['average_fitness'], average, 'average_trace_fitness')
    close(fitness['perfectly_fitting_frac'], Fraction(perfect, total), 'perfect_fraction')
    return {'log_fitness': str(log), 'average_fitness': str(average),
            'perfect_fraction': str(Fraction(perfect, total)), 'total_cost': weighted}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    directory = args.directory.absolute()
    manifest_bytes = read(directory / 'manifest.json')
    manifest = loads(manifest_bytes)
    check(manifest['kind'] == 'FINITE_PINNED_ALPHA_PETRI_ALIGNMENT_EVIDENCE' and
          manifest['schema_version'] == 1 and manifest['not_acceptance'] is True, 'manifest_contract')
    check(len(manifest['files']) <= 20, 'file_count_limit')
    paths = {}
    total = 0
    for entry in manifest['files']:
        name = entry['path']
        parts = PurePosixPath(name)
        check(not parts.is_absolute() and '..' not in parts.parts and '\\' not in name and
              ':' not in name and name not in paths and name != 'manifest.json', 'safe_manifest_path')
        data = read(directory / name)
        check(len(data) == entry['bytes'] and sha(data) == entry['sha256'].lower(), 'full_original_file_hash')
        paths[name] = data
        total += len(data)
    check(total <= 64 * 1024 * 1024, 'total_limit')
    actual = set()
    for path in directory.rglob('*'):
        no_link(path)
        if path.is_file():
            actual.add(path.relative_to(directory).as_posix())
    check(actual == set(paths) | {'manifest.json'}, 'complete_file_set')
    check(sha(paths['corpus.json']) == CORPUS_SHA == manifest['corpus_sha256'], 'frozen_corpus')
    corpus = loads(paths['corpus.json'])
    bundle = loads(paths['bundle.json'])
    result = loads(paths['alignment-results.json'])
    provenance = loads(paths['provenance.json'])
    check(result['bundle_sha256'] == sha(paths['bundle.json']) and
          result['corpus_sha256'] == bundle['corpus_sha256'] == CORPUS_SHA, 'phase_hash_binding')
    check(result['phase'] == 'align_only_no_discovery' and bundle['phase'] == 'mine_only_no_alignment', 'separate_phase')
    pins = {row['path']: row['sha256'].lower() for row in provenance['source_files']}
    check(bundle['observer_source_sha256'] == result['observer_source_sha256'] ==
          pins['examples/discovery_fitness.rs'], 'observer_source_binding')
    check(re.fullmatch('[0-9a-f]{40}', provenance['source_commit']) and provenance['not_acceptance'] is True,
          'provenance_contract')
    check(len(provenance['process_summaries']) >= 3, 'native_summaries')
    summary_labels = [summary['label'] for summary in provenance['process_summaries']]
    check(len(summary_labels) == len(set(summary_labels)) and
          {'build', 'mine', 'align'} <= set(summary_labels), 'unique_required_native_labels')
    for summary in provenance['process_summaries']:
        check(re.fullmatch('[0-9a-f]{64}', summary['original_sha256']) and summary['original_bytes'] > 0,
              'original_summary_provenance')
        selected = summary['selected_fields']
        native = selected.get('native', selected)
        if 'native_exit' in native:
            check(native['native_exit'] == 0 and native.get('stdout_complete') is True and
                  native.get('stderr_complete') is True and not native.get('output_limit') and
                  not native.get('capture_fault') and not native.get('drain_timeout'), 'native_exit_capture')
        else:
            check(all(native.get(key) == 0 for key in ['fmt_native_exit', 'test_native_exit', 'build_native_exit']),
                  'build_exit_fields')
    cases = {row['id']: row for row in corpus['cases']}
    check(len(cases) == 12 and len(corpus['cases']) == 12, 'twelve_cases')
    manual_rows = result['manual_reference_checks']
    check(manual_rows['all_manual_checks_pass'] is True and len(manual_rows['cases']) == 9,
          'manual_status')
    manual_ids = [row['id'] for row in manual_rows['cases']]
    check(len(manual_ids) == len(set(manual_ids)) and
          set(manual_ids) == {f'M{i:02}' for i in range(1, 10)}, 'exact_unique_manual_cases')
    for row in manual_rows['cases']:
        spec = cases[row['id']]
        check(row['expected'] == spec and row['passed'] is True, 'frozen_manual_expectations')
        rows = ([{'sequence': cases[identity]['sequence'], 'frequency': cases[identity]['frequency']}
                 for identity in spec['aggregate_case_ids']] if row['id'] == 'M09' else [spec])
        validate_measurement(row['measurement'], rows,
                             net=manual_net(corpus['manual_nets'][spec['net']]))
        for variant in row['measurement']['alignments']:
            check(variant['result']['Ok']['cost'] == ideal_cost(spec['net'], variant['activities']),
                  'independent_manual_optimum')
        check(row['measurement']['empty_alignment']['cost'] ==
              min(map(len, MANUAL_LANGUAGES[spec['net']])), 'manual_empty_optimum')
        if row['id'] != 'M09':
            check(ideal_cost(spec['net'], spec['sequence']) == spec['expected_cost'], 'independent_manual_cost')
            close(Fraction(spec['expected_fitness']), reference_fitness(rows, spec['net'])[2], 'manual_rational')
        else:
            cost, denominator, log, average, perfect = reference_fitness(rows, spec['net'])
            check(cost == spec['expected_weighted_total_cost'] and denominator == spec['expected_denominator'],
                  'manual_weighting_hypothesis')
            check((log, average, perfect) == tuple(Fraction(spec[k]) for k in
                  ['expected_log_fitness', 'expected_average_trace_fitness', 'expected_perfect_fraction']),
                  'independent_manual_fractions')
    originals = {row['id']: row for row in bundle['nets']}
    observations = result['actual_alpha_observations']
    check(len(originals) == len(bundle['nets']) == len(observations) == 3 and
          {row['id'] for row in observations} == set(originals) == {'A10', 'A11', 'A12'}, 'three_alpha_nets')
    measurements = []
    for row in observations:
        identity = row['id']
        spec = cases[identity]
        original = originals[identity]
        check(row['frozen_ideal_hypothesis'] == spec and row['net_sha256'] == original['net_sha256'],
              'frozen_alpha_hypothesis')
        for suffix, key in [('net.json', 'net_sha256'), ('pnml', 'pnml_sha256'), ('training.json', 'training_sha256')]:
            check(sha(paths[f'nets/{identity}.{suffix}']) == original[key], 'saved_artifact_binding')
        check(original['algorithm'] == 'alpha+++' and original['library'] == 'process_mining@0.6.2',
              'actual_miner_identity')
        training = loads(paths[f'nets/{identity}.training.json'])
        check(Counter(tuple(event['activity'] for event in case['events']) for case in training['cases']) ==
              variants(spec['training']), 'training_only_miner_input')
        net = loads(paths[f'nets/{identity}.net.json'])
        groups = {group['group']: group for group in row['evaluations']}
        check(len(groups) == len(row['evaluations']) == 2 and
              set(groups) == {'training', 'diagnostic_held_out'}, 'separate_eval_groups')
        for name, group in groups.items():
            check(group['frozen_input'] == spec[name], 'frozen_group_input')
            measured = validate_measurement(group['measurement'], spec[name], net=net)
            measurements.append({'id': identity, 'group': name, **measured})
        # Check ideal hypotheses independently, but do NOT force mined results to them.
        costs = [ideal_cost(spec['ideal_ground_truth_net'], variant['sequence'])
                 for variant in spec['diagnostic_held_out']]
        check(costs == spec['ideal_held_out_costs'], 'ideal_hypothesis_costs')
        ideal = reference_fitness(spec['diagnostic_held_out'], spec['ideal_ground_truth_net'])
        check(ideal[2] == Fraction(spec['ideal_held_out_log_fitness']) and
              ideal[3] == Fraction(spec['ideal_held_out_average']), 'ideal_hypothesis_fractions')
    print(json.dumps({'status': 'PASS_OFFLINE_FINITE_ALIGNMENT_ARTIFACT_VERIFICATION',
                      'manifest_sha256': sha(manifest_bytes), 'original_file_count': len(paths),
                      'actual_alpha_groups': measurements,
                      'limits': 'Analytic tiny references and full paths/weights checked; mined global optimality relies on pinned upstream Dijkstra under verified token bounds. No external replication/BPMN/precision/simplicity/generalization/full R4 acceptance.'}))


if __name__ == '__main__':
    main()
