"""Audit the frozen eight-row historical miner cohort without running any engine.

Reuses the separately reviewed independent metric/path/prefix implementation.
Checks original XES lineage, exact raw XML span subtraction, conserved complete
weighted graphs and accepting-language equivalence before checking scalar data.
Historical failures and unsupported behavior remain rows, never hidden successes.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import xml.etree.ElementTree as ET

if not __debug__:
    raise RuntimeError('audit_requires_assertions_enabled')

COHORT = '6dac7a9b69d553590f342ed4b836140678a9f2c072cc806119f0ecc48ace208d'
AUDITOR = '8c60582d3e64c1ca2197fd1ebf9189d8ce96d568b93e9cd6d34c9395fcba47a6'
REFERENCE = '3088b0d864a21b5946aab207a3a1cf4d89204a817e468f9185c96b72a6a0fd9b'
PM_SOURCE = {
    'pm4py.algo.evaluation.precision.variants.align_etconformance': '6c29314c049629a38b2bd969b3ae07ab83dc814c4185a56f507dd0b1d161a39e',
    'pm4py.algo.evaluation.precision.utils': '62a2641b8f9ace1b7e508cc97bde4d8cae5cf57ccb36f3b15f695c0cfbbed524',
    'pm4py.objects.petri_net.utils.align_utils': '99207fdb93fc442e21761d9296b201d638d60c2bc22ea89d42c5d7fd68e064c2',
    'pm4py.algo.evaluation.simplicity.variants.arc_degree': '84edf8a85a7cb3e313056b58493b430b960ffc47cbb57efe6559d924b36249f7',
    'pm4py.objects.conversion.bpmn.variants.to_petri_net': '257441ca99bcede7d9ec356998a8e2b55a8274c8eca52e381f42c471c19ffad1',
}


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def raw(path):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size <= 32 * 1024 * 1024
    value = path.read_bytes()
    assert len(value) <= 32 * 1024 * 1024
    return value


def digest(value):
    return hashlib.sha256(value).hexdigest()


def load(path):
    return json.loads(raw(path))


def child(root, name):
    assert isinstance(name, str) and name not in {'', '.', '..'}
    assert not any(c in name for c in '/\\:')
    return root / name


def index(rows):
    result = {row['id']: row for row in rows}
    assert len(result) == len(rows) == 8, 'all_eight_unique_rows_required'
    return result


def lineage(data, source):
    assert digest(data) == source['sha256'].lower() and len(data) == source['bytes']
    assert b'<!DOCTYPE' not in data and b'<!ENTITY' not in data
    root = ET.fromstring(data)
    traces = []
    for trace in root:
        if trace.tag.rsplit('}', 1)[-1] != 'trace':
            continue
        names = [x.get('value') for x in trace if x.get('key') == 'concept:name']
        assert len(names) == 1
        sequence = []
        for event in trace:
            if event.tag.rsplit('}', 1)[-1] == 'event':
                labels = [x.get('value') for x in event if x.get('key') == 'concept:name']
                assert len(labels) == 1
                sequence.append(labels[0])
        traces.append({'source_trace_index': len(traces), 'source_trace_name': names[0],
                       'sequence': sequence, 'event_count': len(sequence)})
    assert traces == source['traces'] and len(traces) == source['trace_count']
    assert sum(t['event_count'] for t in traces) == source['event_count']
    expected = {tuple(r['sequence']): r['frequency'] for r in source['training_log']}
    assert len(expected) == len(source['training_log'])
    assert Counter(tuple(t['sequence']) for t in traces) == expected
    assert source['heldout_log'] is None, 'no_invented_heldout'


def subtract(source, report, literal, count):
    assert report['projection_status'] == 'projected'
    assert report['original_sha256'] == digest(source) and report['original_bytes'] == len(source)
    positions = [i for i in range(len(source)) if source.startswith(literal, i)]
    assert len(positions) == len(report['removed_spans']) == count
    parts, cursor = [], 0
    for position, span in zip(positions, report['removed_spans']):
        assert span['byte_start'] == position and span['byte_length'] == len(literal)
        assert span['raw_utf8'].encode() == literal and span['subtree_sha256'] == digest(literal)
        parts.append(source[cursor:position])
        cursor = position + len(literal)
    parts.append(source[cursor:])
    result = b''.join(parts)
    assert report['projected_sha256'] == digest(result) and report['projected_bytes'] == len(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('corpus', 'prepared', 'conversion', 'rust', 'reference', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    assert digest(raw(args.corpus)) == COHORT
    assert digest(raw(Path(__file__).with_name('audit-quality-evidence.py'))) == AUDITOR
    audit = module('independent_metric_audit', 'audit-quality-evidence.py')
    validate = module('net_graph_conservation', 'validate-quality-net-graph.py').validate
    compare = module('accepting_language_equivalence', 'compare-quality-graphs.py').compare
    corpus = load(args.corpus)
    cases = index(corpus['cases'])
    bundle_bytes = raw(args.prepared / 'bundle.json')
    bundle = json.loads(bundle_bytes)
    projection_bytes = raw(args.prepared / 'projection.json')
    projection = json.loads(projection_bytes)
    rust, reference = load(args.rust), load(args.reference)
    conversion = load(args.conversion / 'reference-conversions.json')
    for value in (bundle, projection, rust, reference, conversion):
        assert value['cohort_sha256'] == COHORT
    for value in (rust, reference, conversion):
        assert value['bundle_sha256'] == digest(bundle_bytes)
    assert digest(projection_bytes) == bundle['projection_sha256']
    assert digest(raw(args.prepared / 'inputs/corpus.json')) == COHORT
    assert bundle['phase'] == 'miner_prepare_only_no_fitness_or_precision'
    assert rust['phase'] == 'miner_score_saved_only_no_conversion_or_mining'
    assert reference['phase'] == 'miner_unchanged_pm4py_same_saved_net_metrics'
    assert rust['sources'] == bundle['sources']
    for value in (reference, conversion):
        assert value['base_adapter_sha256'] == REFERENCE and value['source_pins'] == PM_SOURCE
    for filename, expected in projection['sources'].items():
        assert bundle['sources'][filename] == expected
    artifacts = bundle['artifacts']
    R, F, C, P = (index(value['cases']) for value in (rust, reference, conversion, projection))
    assert set(cases) == set(artifacts) == set(R) == set(F) == set(C) == set(P)
    output = []
    for identity, case in cases.items():
        artifact = artifacts[identity]
        record = artifact['prepared']
        assert artifact['source_input'] == case['source_input']
        assert artifact['carried_actual_outcome'] == case['carried_actual_outcome']
        assert artifact['projection'] == P[identity]
        assert P[identity]['source_input'] == case['source_input']
        lineage(raw(child(args.prepared / 'inputs', identity + '.xes')), case['source_input'])
        rr, ff, cc = R[identity], F[identity], C[identity]
        if case['raw_bpmn'] is None:
            assert identity == 'empty-log'
            assert rr['result'] == record and record['status'] == 'carried_algorithm_exception'
            assert record['exception'] == case['carried_actual_outcome']['exception']
            assert cc['status'] == 'carried_algorithm_exception'
            assert ff['status'] == 'not_executed_rust_admission_refused' and 'groups' not in ff
            output.append({'id': identity, 'status': 'historical_empty_log_exception_retained'})
            continue
        original = raw(child(args.prepared / 'inputs', identity + '.raw.bpmn'))
        assert digest(original) == case['raw_bpmn']['sha256'].lower()
        assert len(original) == case['raw_bpmn']['bytes']
        if identity == 'self-loop':
            assert b'standardLoopCharacteristics' in original
            assert rr['result'] == record
            assert record['reason'] == 'quality_unsupported_standard_loop_before_both_converters'
            assert cc['status'] == 'reference_conversion_refused'
            assert ff['status'] == 'raw_compatibility_refused' and 'groups' not in ff
            output.append({'id': identity, 'status': 'unsupported_standard_loop_retained'})
            continue
        assert record['admission_status'] == 'admitted'
        h = load(child(args.prepared / 'projection', identity + '.hint.json'))
        d = load(child(args.prepared / 'projection', identity + '.di.json'))
        intermediate = subtract(original, h, b'xsi:schemaLocation="http://www.omg.org/spec/BPMN/20100524/MODEL BPMN20.xsd"', 1)
        assert intermediate == raw(child(args.prepared / 'projection', identity + '.hint.bpmn'))
        projected = subtract(intermediate, d, b'<bpmndi:BPMNLabel/>', case['static_features']['bpmnlabel_DI_count'])
        assert projected == raw(child(args.prepared / 'projection', identity + '.projected.bpmn'))
        assert h['semantic_map'] == d['semantic_map']
        netbytes = raw(child(args.prepared / 'nets', record['net_file']))
        assert digest(netbytes) == record['net_sha256'] == rr['net_sha256'] == ff['net_sha256']
        for folder, key in [('maps', 'map'), ('graphs', 'graph')]:
            assert digest(raw(child(args.prepared / folder, record[key + '_file']))) == record[key + '_sha256']
        graph = rr['result']['graph']
        validate(netbytes, graph)
        saved_graph = load(child(args.prepared / 'graphs', record['graph_file']))
        assert graph == saved_graph.get('graph', saved_graph)
        assert cc['status'] == 'converted_original_raw_xml'
        assert cc['original_sha256'].lower() == digest(original)
        refnet = raw(child(args.conversion, cc['net_file']))
        refgraphbytes = raw(child(args.conversion, cc['graph_file']))
        assert digest(refnet) == cc['net_sha256'] and digest(refgraphbytes) == cc['graph_sha256']
        refgraph = json.loads(refgraphbytes)
        validate(refnet, refgraph)
        equivalent = compare(graph, refgraph.get('graph', refgraph))
        assert equivalent['status'] == 'equivalent'
        groups = rr['result']['groups']
        assert len(groups) == len(ff['groups']) == 1
        for group in groups + ff['groups']:
            assert group['group'] == 'training_log' and group['input'] == case['source_input']['training_log']
        checks = audit.verify(graph, json.loads(netbytes), groups, ff['groups'], bundle['limits'])
        output.append({'id': identity, 'status': 'conserved_equivalent_and_independently_audited',
                       'equivalence': equivalent, 'groups': checks})
    result = {'schema_version': 1, 'status': 'independent_eight_row_miner_cohort_audit_passed',
              'cohort_sha256': COHORT, 'bundle_sha256': digest(bundle_bytes),
              'rust_sha256': digest(raw(args.rust)), 'reference_sha256': digest(raw(args.reference)),
              'cases': output, 'not_whole_R4_acceptance': True,
              'scope': 'Historical miner source-training cohort only; exact projection, full conserved accepting languages, independent costs/paths/rational/prefix metrics. Unsupported loop and empty exception remain explicit; no new mining or heldout evidence.'}
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=True, indent=2)
        stream.write('\n')
    print(json.dumps({'status': result['status'], 'cases': len(output),
                      'output_sha256': digest(raw(args.output))}))


if __name__ == '__main__':
    main()
