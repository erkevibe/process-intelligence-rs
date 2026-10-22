"""Unchanged PM4Py APIs: original miner XML conversion or exact saved-net metrics."""
import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE_SHA = '3088b0d864a21b5946aab207a3a1cf4d89204a817e468f9185c96b72a6a0fd9b'
COHORT_SHA = '6dac7a9b69d553590f342ed4b836140678a9f2c072cc806119f0ecc48ace208d'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def load(directory, base):
    raw = base.read(directory / 'bundle.json')
    bundle = json.loads(raw)
    corpus_bytes = base.read(directory / 'inputs' / 'corpus.json')
    base.require(base.sha(corpus_bytes) == COHORT_SHA and bundle['cohort_sha256'] == COHORT_SHA
                 and bundle['phase'] == 'miner_prepare_only_no_fitness_or_precision', 'cohort_bundle_phase')
    projection_bytes = base.read(directory / 'projection.json')
    base.require(base.sha(projection_bytes) == bundle['projection_sha256'], 'projection_receipt_hash')
    corpus = json.loads(corpus_bytes)
    base.require(len(bundle['artifacts']) == 8 and set(bundle['artifacts']) == {r['id'] for r in corpus['cases']},
                 'all_eight_cohort_rows')
    # Source pins are actual source bytes, not caller-supplied names.
    for file, expected in bundle['sources'].items():
        if file == 'base':
            for nested, digest in expected.items():
                base.require(base.sha(base.read(ROOT / nested)) == digest, 'base_source_pin:' + nested)
        else:
            base.require(base.sha(base.read(ROOT / file)) == expected, 'cohort_source_pin:' + file)
    for case in corpus['cases']:
        record = bundle['artifacts'][case['id']]
        base.require(record['source_input'] == case['source_input'], 'original_training_binding')
        xes = base.read(directory / 'inputs' / (case['id'] + '.xes'))
        base.require(base.sha(xes) == case['source_input']['sha256'].lower(), 'original_xes_binding')
    return bundle, corpus, base.sha(raw)


def raw_guard(directory, case, base):
    path = directory / 'inputs' / (case['id'] + '.raw.bpmn')
    raw = base.read(path)
    base.require(base.sha(raw) == case['raw_bpmn']['sha256'].lower(), 'original_raw_bpmn_hash')
    # Same unchanged projectors perform namespace-aware behavioral refusal on raw XML.
    # Only their guards/reports are used here. The actual reference importer gets path (raw).
    project = module('cohort_project_guard', ROOT / 'tools/sprint19/quality-miner-project.py')
    hint = project.module('cohort_hint_guard', 'schema-hint.py', project.HINT_SHA)
    di = project.module('cohort_di_guard', 'quality-di.py', project.DI_SHA)
    intermediate, _ = hint.project(raw)
    di.project(intermediate)
    return path


def convert(directory, output, base, libraries):
    bundle, corpus, bundle_hash = load(directory, base)
    output.mkdir()
    rows = []
    for case in corpus['cases']:
        identity = case['id']
        record = bundle['artifacts'][identity]['prepared']
        row = {'id': identity, 'original_rust_prepared': record}
        if case['raw_bpmn'] is None:
            row.update(status='carried_algorithm_exception', exception=case['carried_actual_outcome']['exception'])
            rows.append(row)
            continue
        try:
            original = raw_guard(directory, case, base)
            if record.get('admission_status') != 'admitted':
                row.update(status='not_executed_rust_admission_refused')
                rows.append(row)
                continue
            bpmn = libraries['importer'].apply(str(original))
            net, im, fm = libraries['converter'].apply(
                bpmn, parameters={'use_id': False, 'enable_reduction': False})
            structure, places, transitions = base.serialize_net(net, im, fm)
            net_bytes = base.encoded(structure)
            graph = base.full_graph(net, im, fm, libraries, base.sha(net_bytes))
            graph['places'] = [places[next(p for p in net.places if str(p.name) == name)]
                               for name in graph['places']]
            for item in graph['transitions']:
                item['id'] = transitions[next(t for t in net.transitions if str(t.name) == item['id'])]
            for item in graph['edges']:
                item['transition'] = transitions[next(t for t in net.transitions if str(t.name) == item['transition'])]
            graph_bytes = base.encoded(graph)
            base.write(output / (identity + '.net.json'), net_bytes)
            base.write(output / (identity + '.graph.json'), graph_bytes)
            row.update(status='converted_original_raw_xml', original_sha256=case['raw_bpmn']['sha256'],
                       net_sha256=base.sha(net_bytes), graph_sha256=base.sha(graph_bytes),
                       net_file=identity + '.net.json', graph_file=identity + '.graph.json')
        except Exception as error:
            row.update(status='reference_conversion_refused', exception_class=type(error).__name__,
                       reason=str(error), scalar=None)
        rows.append(row)
    base.write(output / 'reference-conversions.json', base.encoded({
        'schema_version': 1, 'phase': 'miner_unchanged_pm4py_original_raw_conversion',
        'bundle_sha256': bundle_hash, 'cohort_sha256': COHORT_SHA,
        'base_adapter_sha256': BASE_SHA, 'source_pins': libraries['pins'],
        'cases': rows, 'not_acceptance': True}))


def score(directory, output, base, libraries):
    bundle, corpus, bundle_hash = load(directory, base)
    rows = []
    for case in corpus['cases']:
        identity = case['id']
        artifact = bundle['artifacts'][identity]
        record = artifact['prepared']
        row = {'id': identity}
        if case['raw_bpmn'] is not None:
            try:
                raw_guard(directory, case, base)
            except Exception as error:
                row.update(status='raw_compatibility_refused', exception_class=type(error).__name__, reason=str(error))
                rows.append(row)
                continue
        if record.get('admission_status') != 'admitted':
            row.update(status='not_executed_rust_admission_refused', original_rust_prepared=record)
            rows.append(row)
            continue
        raw_bytes = base.read(directory / 'nets' / base.checked_name(record['net_file']))
        base.require(base.sha(raw_bytes) == record['net_sha256'], 'same_saved_net_hash')
        for folder, key in [('maps', 'map'), ('graphs', 'graph')]:
            data = base.read(directory / folder / base.checked_name(record[key + '_file']))
            base.require(base.sha(data) == record[key + '_sha256'], 'same_saved_' + key + '_hash')
        try:
            result = base.evaluate(json.loads(raw_bytes), case['source_input']['training_log'],
                                   libraries, record['net_sha256'])
        except Exception as error:
            result = {'status': 'reference_inconclusive', 'exception_class': type(error).__name__,
                      'reason': str(error), 'scalar': None}
        row.update(net_sha256=record['net_sha256'], groups=[{
            'group': 'training_log', 'input': case['source_input']['training_log'], 'result': result}])
        rows.append(row)
    base.write(output, base.encoded({'schema_version': 1,
        'phase': 'miner_unchanged_pm4py_same_saved_net_metrics',
        'bundle_sha256': bundle_hash, 'cohort_sha256': COHORT_SHA,
        'base_adapter_sha256': BASE_SHA, 'source_pins': libraries['pins'],
        'cases': rows, 'not_acceptance': True}))


if __name__ == '__main__':
    import hashlib
    path = ROOT / 'tools/sprint19/quality-reference.py'
    if hashlib.sha256(path.read_bytes()).hexdigest() != BASE_SHA:
        raise ValueError('frozen_base_reference_adapter_hash')
    base = module('frozen_quality_reference', path)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['convert', 'score'])
    parser.add_argument('prepared', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    libraries = base.api()
    (convert if args.operation == 'convert' else score)(args.prepared, args.output, base, libraries)
