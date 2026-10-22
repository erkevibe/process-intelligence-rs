"""Unchanged PM4Py 2.7.17 reference APIs; separate conversion and same-net scoring.

No import patching, extracted substitute implementation or finite trace-language
oracle. Invoke only through the reviewed supervisor after dependency admission.
"""
import argparse
from collections import Counter, deque
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import sys

EXPECTED_CORPUS = '618708791670d89f730282ac0a7e0dd1eb39c59600a5362684bb71fdc3e40410'
SOURCE_PINS = {
    'pm4py.algo.evaluation.precision.variants.align_etconformance': '6c29314c049629a38b2bd969b3ae07ab83dc814c4185a56f507dd0b1d161a39e',
    'pm4py.algo.evaluation.precision.utils': '62a2641b8f9ace1b7e508cc97bde4d8cae5cf57ccb36f3b15f695c0cfbbed524',
    'pm4py.objects.petri_net.utils.align_utils': '99207fdb93fc442e21761d9296b201d638d60c2bc22ea89d42c5d7fd68e064c2',
    'pm4py.algo.evaluation.simplicity.variants.arc_degree': '84edf8a85a7cb3e313056b58493b430b960ffc47cbb57efe6559d924b36249f7',
    'pm4py.objects.conversion.bpmn.variants.to_petri_net': '257441ca99bcede7d9ec356998a8e2b55a8274c8eca52e381f42c471c19ffad1',
}


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024,
            'artifact_limit_or_type')
    data = path.read_bytes()
    require(len(data) <= 16 * 1024 * 1024, 'artifact_grew')
    return data


def write(path, data):
    with path.open('xb') as stream:
        stream.write(data)


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode()


def checked_name(name):
    require(name and '/' not in name and '\\' not in name and ':' not in name and name not in {'.', '..'},
            'unsafe_artifact_name')
    return name


def api():
    import importlib
    import pm4py
    from importlib.metadata import version
    require(version('pm4py') == '2.7.17', 'pm4py_version')
    modules = {}
    pins = {}
    for name, expected in SOURCE_PINS.items():
        module = importlib.import_module(name)
        actual = sha(read(Path(module.__file__)))
        require(actual == expected, 'actual_reference_source_pin:' + name)
        modules[name] = module
        pins[name] = actual
    from pm4py.objects.petri_net.obj import PetriNet, Marking
    from pm4py.objects.petri_net import semantics
    from pm4py.objects.petri_net.utils.petri_utils import add_arc_from_to
    from pm4py.objects.log.obj import EventLog, Trace, Event
    from pm4py.algo.conformance.alignments.petri_net.variants import dijkstra_no_heuristics
    from pm4py.objects.bpmn.importer import importer
    from pm4py.objects.conversion.bpmn import converter
    from pm4py.util import constants
    return locals()


def load_bundle(directory):
    raw = read(directory / 'bundle.json')
    bundle = json.loads(raw)
    require(bundle['phase'] == 'prepare_only_no_fitness_or_precision' and
            bundle['corpus_sha256'] == EXPECTED_CORPUS, 'prepared_phase_or_corpus')
    corpus_bytes = read(directory / 'inputs/corpus.json')
    require(sha(corpus_bytes) == EXPECTED_CORPUS, 'copied_corpus_pin')
    return bundle, json.loads(corpus_bytes), sha(raw)


def activity_encoding(labels):
    # PM4Py prefixes use a delimiter string; injective names avoid collisions.
    return {label: f'L{index:06}' for index, label in enumerate(sorted(set(labels)))}


def from_rust(raw, libraries, additional_labels=()):
    net = libraries['PetriNet']('exact_saved_rust_net')
    labels = [row['label'] for row in raw['transitions'].values() if row['label'] is not None]
    code = activity_encoding([*labels, *additional_labels])
    places = {}
    transitions = {}
    for identity, value in raw['places'].items():
        require(value['id'] == identity, 'place_id')
        places[identity] = libraries['PetriNet'].Place(identity)
        net.places.add(places[identity])
    for identity, value in raw['transitions'].items():
        require(value['id'] == identity, 'transition_id')
        label = None if value['label'] is None else code[value['label']]
        transitions[identity] = libraries['PetriNet'].Transition(identity, label)
        net.transitions.add(transitions[identity])
    ends = set()
    for arc in raw['arcs']:
        source, target = arc['from_to']['nodes']
        require((source, target) not in ends and 0 < arc['weight'] <= 255, 'arc_admission')
        ends.add((source, target))
        if arc['from_to']['type'] == 'PlaceTransition':
            origin, destination = places[source], transitions[target]
        else:
            require(arc['from_to']['type'] == 'TransitionPlace', 'arc_kind')
            origin, destination = transitions[source], places[target]
        libraries['add_arc_from_to'](origin, destination, net, weight=arc['weight'])
    require(raw['initial_marking'] is not None and len(raw['final_markings']) == 1, 'single_markings')
    im = libraries['Marking']({places[p]: n for p, n in raw['initial_marking'].items() if n})
    fm = libraries['Marking']({places[p]: n for p, n in raw['final_markings'][0].items() if n})
    reverse = {value: key for key, value in code.items()}
    return net, im, fm, code, reverse


def full_graph(net, im, fm, libraries, net_hash, reverse=None):
    places = sorted(net.places, key=lambda place: str(place.name))
    require(len({str(p.name) for p in places}) == len(places), 'unique_place_names')
    transitions = sorted(net.transitions, key=lambda transition: str(transition.name))
    require(len({str(t.name) for t in transitions}) == len(transitions), 'unique_transition_names')
    require(len(places) + len(transitions) <= 128 and len(net.arcs) <= 256, 'generated_graph_limits')
    label = lambda transition: (None if transition.label is None else
                                reverse[transition.label] if reverse else transition.label)
    vector = lambda marking: tuple(int(marking.get(place, 0)) for place in places)
    initial = vector(im)
    target = vector(fm)
    states = [initial]
    identities = {initial: 0}
    queue = deque([im])
    edges = []
    while queue:
        marking = queue.popleft()
        source = identities[vector(marking)]
        for transition in sorted(libraries['semantics'].enabled_transitions(net, marking),
                                 key=lambda transition: str(transition.name)):
            following = libraries['semantics'].execute(transition, net, marking)
            tokens = vector(following)
            require(all(0 <= value <= 255 for value in tokens), 'token_bound_exceeded')
            if tokens not in identities:
                require(len(states) < 10000, 'reachable_marking_budget')
                identities[tokens] = len(states)
                states.append(tokens)
                queue.append(following)
            edges.append({'from': source, 'to': identities[tokens],
                          'transition': str(transition.name), 'label': label(transition)})
    require(target in identities, 'final_marking_unreachable')
    final = identities[target]
    reverse_edges = [[] for _ in states]
    for edge in edges:
        reverse_edges[edge['to']].append(edge['from'])
    can_finish = {final}
    queue = deque([final])
    while queue:
        for source in reverse_edges[queue.popleft()]:
            if source not in can_finish:
                can_finish.add(source)
                queue.append(source)
    require(len(can_finish) == len(states), 'reachable_marking_has_no_path_to_final')
    return {'schema_version': 1, 'net_sha256': net_hash,
            'places': [str(p.name) for p in places],
            'transitions': [{'id': str(t.name), 'label': label(t)} for t in transitions],
            'initial_state': 0, 'final_states': [final], 'states': states, 'edges': edges}


def serialize_net(net, im, fm):
    places = {place: 'p:' + str(place.name) for place in net.places}
    transitions = {transition: 't:' + str(transition.name) for transition in net.transitions}
    require(len(set(places.values())) == len(places) and len(set(transitions.values())) == len(transitions),
            'conversion_unique_names')
    result = {'places': {identity: {'id': identity} for identity in sorted(places.values())},
              'transitions': {identity: {'id': identity, 'label': transition.label}
                              for transition, identity in sorted(transitions.items(), key=lambda item: item[1])},
              'arcs': [], 'initial_marking': {places[p]: n for p, n in im.items()},
              'final_markings': [{places[p]: n for p, n in fm.items()}]}
    for arc in net.arcs:
        if arc.source in places:
            kind, nodes = 'PlaceTransition', [places[arc.source], transitions[arc.target]]
        else:
            kind, nodes = 'TransitionPlace', [transitions[arc.source], places[arc.target]]
        result['arcs'].append({'from_to': {'type': kind, 'nodes': nodes}, 'weight': arc.weight})
    result['arcs'].sort(key=lambda arc: tuple(arc['from_to']['nodes']))
    return result, places, transitions


def expanded(corpus):
    output = []
    for parent in corpus['cases']:
        base = {key: value for key, value in parent.items() if key != 'subcases'}
        if 'model' in base or 'manual_net' in base:
            output.append(base)
        output.extend({**base, **child} for child in parent.get('subcases', []))
    return output


def event_log(rows, code, libraries):
    log = libraries['EventLog']()
    for variant in rows:
        for _ in range(variant['frequency']):
            trace = libraries['Trace']()
            for activity in variant['sequence']:
                trace.append(libraries['Event']({'concept:name': code[activity]}))
            log.append(trace)
    return log


def evaluate(raw, rows, libraries, lower_caps=None):
    caps = {'reachable_markings': 10000, 'fitness_search_states': 100000,
            'prefix_search_states': 100000, 'tau_closure_markings': 10000}
    for name, value in (lower_caps or {}).items():
        if name == 'equivalence_subset_pairs':
            continue
        require(name in caps and isinstance(value, int) and 0 < value <= caps[name],
                'test_cap_not_lowering')
        caps[name] = value
    counts = Counter()
    for variant in rows:
        counts[tuple(variant['sequence'])] += variant['frequency']
    labels = [activity for sequence in counts for activity in sequence]
    net, im, fm, code, reverse = from_rust(raw, libraries, labels)
    graph = full_graph(net, im, fm, libraries, sha(encoded(raw)), reverse)
    require(len(graph['states']) <= caps['reachable_markings'], 'reachable_marking_budget')
    simple_api = libraries['modules']['pm4py.algo.evaluation.simplicity.variants.arc_degree']
    simplicity = simple_api.apply(net, parameters={'k': 2})
    if not counts:
        return {'fitness': {'status': 'no_data'}, 'precision': {'status': 'no_data'},
                'simplicity': {'status': 'measured', 'scalar': simplicity}}
    parameters = {'model_cost_function': {t: 0 if t.label is None else 1 for t in net.transitions},
                  'sync_cost_function': {t: 0 for t in net.transitions},
                  'ret_tuple_as_trans_desc': True, 'max_align_time_trace': 30}
    alignment = libraries['dijkstra_no_heuristics']
    def align(sequence):
        require(len(graph['states']) * (len(sequence) + 1) <= caps['fitness_search_states'],
                'reference_fitness_upper_bound_inconclusive')
        trace = event_log([{'sequence': sequence, 'frequency': 1}], code, libraries)[0]
        result = alignment.apply(trace, net, im, fm,
                                 parameters={**parameters, 'trace_cost_function': [1] * len(sequence)})
        require(result is not None and result['visited_states'] <= caps['fitness_search_states'], 'alignment_inconclusive')
        return result
    empty = align(())
    variants = [{'activities': sequence, 'frequency': frequency, 'result': align(sequence)}
                for sequence, frequency in sorted(counts.items())]
    total = sum(counts.values())
    cost = sum(row['frequency'] * row['result']['cost'] for row in variants)
    denominator = sum(frequency * (len(sequence) + empty['cost'])
                      for sequence, frequency in counts.items())
    log_fitness = 1 - Fraction(cost, denominator) if denominator else Fraction(1)
    average = sum((frequency * (1 - Fraction(next(row['result']['cost'] for row in variants
                    if tuple(row['activities']) == sequence), len(sequence) + empty['cost']))
                    if len(sequence) + empty['cost'] else Fraction(frequency)
                    for sequence, frequency in counts.items()), Fraction()) / total
    fit = {'status': 'measured', 'empty_alignment': empty, 'alignments': variants,
           'total_cost': cost, 'denominator': denominator, 'log_fitness': str(log_fitness),
           'average_trace_fitness': str(average),
           'perfectly_fitting_frac': str(Fraction(sum(row['frequency'] for row in variants
                                                     if row['result']['cost'] == 0), total)),
           'costs': {'visible_model': 1, 'log': 1, 'sync': 0, 'tau': 0}}
    if cost:
        precision = {'status': 'requires_fitting_log', 'scalar': None,
                     'nonfitting_trace_frequency': sum(row['frequency'] for row in variants
                                                       if row['result']['cost'])}
    else:
        log = event_log(rows, code, libraries)
        utils = libraries['modules']['pm4py.algo.evaluation.precision.utils']
        precision_api = libraries['modules']['pm4py.algo.evaluation.precision.variants.align_etconformance']
        align_utils = libraries['modules']['pm4py.objects.petri_net.utils.align_utils']
        prefixes, weights = utils.get_log_prefixes(log)
        # The unmodified reference has no live state-limit parameter. This exact
        # finite-state product upper bound prevents exceeding the agreed search cap.
        require(all(len(graph['states']) * (len(key.split(libraries['constants'].DEFAULT_VARIANT_SEP)) + 1)
                    <= caps['prefix_search_states'] for key in prefixes), 'reference_prefix_upper_bound_inconclusive')
        require(len(graph['states']) <= caps['tau_closure_markings'],
                'reference_tau_closure_upper_bound_inconclusive')
        options = {'multiprocessing': False, 'show_progress_bar': False, 'cores': 1}
        stops = precision_api.align_fake_log_stop_marking(utils.form_fake_log(list(prefixes)),
                                                         net, im, fm, parameters=options)
        markings = precision_api.transform_markings_from_sync_to_original_net(stops, net)
        details = []
        activated = escaping = 0
        for key, reached in zip(prefixes, markings):
            require(reached is not None, 'fitting_prefix_unreplayable')
            enabled = set()
            for marking in reached:
                enabled |= {t.label for t in align_utils.get_visible_transitions_eventually_enabled_by_marking(net, marking)}
            enabled.discard(None)
            extra = enabled - set(prefixes[key])
            activated += weights[key] * len(enabled)
            escaping += weights[key] * len(extra)
            details.append({'prefix': [reverse[label] for label in key.split(libraries['constants'].DEFAULT_VARIANT_SEP)],
                            'weight': weights[key], 'stop_markings': [{str(p.name): n for p, n in m.items()} for m in reached],
                            'activated_labels': sorted(reverse[label] for label in enabled),
                            'observed_next_labels': sorted(reverse[label] for label in prefixes[key]),
                            'escaping_labels': sorted(reverse[label] for label in extra)})
        initial_labels = {t.label for t in align_utils.get_visible_transitions_eventually_enabled_by_marking(net, im)}
        initial_labels.discard(None)
        starts = {code[sequence[0]] for sequence in counts if sequence}
        activated += total * len(initial_labels)
        escaping += total * len(initial_labels - starts)
        raw_scalar = precision_api.apply(log, net, im, fm, parameters=options)
        if not activated:
            precision = {'status': 'not_applicable_no_activated_labels', 'scalar': None,
                         'raw_upstream_scalar': raw_scalar, 'activated_weight': 0,
                         'escaping_weight': 0, 'prefixes': details}
        else:
            exact = Fraction(activated - escaping, activated)
            require(abs(raw_scalar - float(exact)) <= 1e-9, 'reference_prefix_component_disagreement')
            precision = {'status': 'measured', 'scalar': raw_scalar, 'rational': str(exact),
                         'activated_weight': activated, 'escaping_weight': escaping,
                         'prefixes': details,
                         'empty_prefix': {'weight': total,
                                          'activated_labels': sorted(reverse[label] for label in initial_labels),
                                          'observed_next_labels': sorted(reverse[label] for label in starts)}}
    return {'fitness': fit, 'precision': precision,
            'simplicity': {'status': 'measured', 'scalar': simplicity, 'k': 2,
                           'places': len(net.places), 'transitions': len(net.transitions),
                           'arcs': len(net.arcs)}, 'activity_encoding': code}


def convert(directory, output, libraries):
    bundle, corpus, bundle_hash = load_bundle(directory)
    output.mkdir()
    records = []
    for identity, artifact in sorted(bundle['artifacts'].items()):
        if artifact['kind'] != 'bpmn_bridge':
            continue
        record = artifact['prepared']
        if record.get('admission_status') != 'admitted':
            records.append({'id': identity, 'status': 'not_executed_rust_admission_refused',
                            'original_rust_prepared': record})
            continue
        path = directory / 'inputs' / checked_name(artifact['input_file'])
        require(sha(read(path)) == artifact['input_sha256'], 'original_bpmn_hash')
        try:
            bpmn = libraries['importer'].apply(str(path))
            net, im, fm = libraries['converter'].apply(
                bpmn, parameters={'use_id': False, 'enable_reduction': False})
            structure, places, transitions = serialize_net(net, im, fm)
            net_bytes = encoded(structure)
            graph = full_graph(net, im, fm, libraries, sha(net_bytes))
            graph['places'] = [places[next(p for p in net.places if str(p.name) == name)] for name in graph['places']]
            for row in graph['transitions']:
                row['id'] = transitions[next(t for t in net.transitions if str(t.name) == row['id'])]
            for edge in graph['edges']:
                edge['transition'] = transitions[next(t for t in net.transitions if str(t.name) == edge['transition'])]
            write(output / (identity + '.net.json'), net_bytes)
            graph_bytes = encoded(graph)
            write(output / (identity + '.graph.json'), graph_bytes)
            records.append({'id': identity, 'status': 'converted', 'net_sha256': sha(net_bytes),
                            'graph_sha256': sha(graph_bytes),
                            'net_file': identity + '.net.json', 'graph_file': identity + '.graph.json'})
        except Exception as error:
            records.append({'id': identity, 'status': 'reference_conversion_refused',
                            'exception_class': type(error).__name__, 'reason': str(error)})
    write(output / 'reference-conversions.json', encoded(
        {'schema_version': 1, 'bundle_sha256': bundle_hash, 'corpus_sha256': EXPECTED_CORPUS,
         'phase': 'unchanged_pm4py_bpmn_conversion', 'source_pins': libraries['pins'],
         'cases': records, 'not_acceptance': True}))


def score(directory, output, libraries):
    bundle, corpus, bundle_hash = load_bundle(directory)
    results = []
    for case in expanded(corpus):
        for kind, key in [('bridge', 'model'), ('manual', 'manual_net')]:
            if key not in case:
                continue
            identity = kind + '-' + case[key]
            record = bundle['artifacts'][identity]['prepared']
            if record.get('admission_status') != 'admitted':
                results.append({'id': case['id'], 'artifact_id': identity,
                                'status': 'not_executed_rust_admission_refused',
                                'original_rust_prepared': record})
                continue
            raw_bytes = read(directory / 'nets' / checked_name(record['net_file']))
            require(sha(raw_bytes) == record['net_sha256'], 'same_saved_net_hash')
            raw = json.loads(raw_bytes)
            groups = []
            for group in ['training_log', 'heldout_log']:
                try:
                    result = evaluate(raw, case[group], libraries, case.get('test_only_lower_caps'))
                except Exception as error:
                    result = {'status': 'reference_inconclusive', 'exception_class': type(error).__name__,
                              'reason': str(error), 'scalar': None}
                groups.append({'group': group, 'input': case[group], 'result': result})
            results.append({'id': case['id'], 'artifact_id': identity,
                            'net_sha256': record['net_sha256'], 'groups': groups})
    write(output, encoded({'schema_version': 1, 'phase': 'unchanged_pm4py_same_saved_net_metrics',
                           'bundle_sha256': bundle_hash, 'corpus_sha256': EXPECTED_CORPUS,
                           'source_pins': libraries['pins'], 'cases': results, 'not_acceptance': True,
                           'limits': 'Reference preflights finite product bound; postchecks actual visited states. No monkeypatch to unchanged search; supervisor enforces native resources.'}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['smoke', 'convert', 'score'])
    parser.add_argument('prepared', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    libraries = api()
    if args.operation == 'smoke':
        functions = {'alignment': libraries['dijkstra_no_heuristics'].apply,
                     'bpmn_import': libraries['importer'].apply,
                     'bpmn_convert': libraries['converter'].apply,
                     'enabled_transitions': libraries['semantics'].enabled_transitions,
                     'execute': libraries['semantics'].execute}
        require(all(callable(function) for function in functions.values()), 'real_apis_unavailable')
        write(args.output, encoded({'status': 'ACTUAL_IMPORT_SOURCE_PIN_API_READINESS_ONLY',
                                   'pm4py_version': '2.7.17', 'source_pins': libraries['pins'],
                                   'callable_apis': sorted(functions),
                                   'not_model_or_metric_execution': True}))
    elif args.operation == 'convert':
        convert(args.prepared, args.output, libraries)
    else:
        score(args.prepared, args.output, libraries)


if __name__ == '__main__':
    main()
