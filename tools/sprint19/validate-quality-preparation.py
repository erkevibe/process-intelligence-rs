"""Audit saved preparation using independent conservation and full-language checks.

No mining, conversion or metric engine is executed here. Complete raw source
receipts and separate independent review remain required for acceptance.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ROOT = Path(__file__).resolve().parents[2]
NET = load_module('quality_conservation', ROOT / 'tools/oracle/validate-quality-net-graph.py')
LANGUAGE = load_module('quality_language', ROOT / 'tools/oracle/compare-quality-graphs.py')
EXPECTED_CORPUS = '618708791670d89f730282ac0a7e0dd1eb39c59600a5362684bb71fdc3e40410'


def raw(path):
    return NET.read(path)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def bound_file(directory, name):
    NET.require(isinstance(name, str) and name and '/' not in name and '\\' not in name
                and ':' not in name and name not in {'.', '..'}, 'artifact_basename')
    return directory / name


def validate(prepared, reference):
    bundle_bytes = raw(prepared / 'bundle.json')
    bundle = json.loads(bundle_bytes)
    corpus_bytes = raw(prepared / 'inputs/corpus.json')
    NET.require(digest(corpus_bytes) == bundle['corpus_sha256'] == EXPECTED_CORPUS,
                'frozen_corpus_identity')
    reference_bytes = raw(reference / 'reference-conversions.json')
    ref = json.loads(reference_bytes)
    NET.require(ref['bundle_sha256'] == digest(bundle_bytes) and
                ref['corpus_sha256'] == EXPECTED_CORPUS, 'reference_bundle_identity')
    cases = {row['id']: row for row in ref['cases']}
    NET.require(len(cases) == len(ref['cases']) <= 100, 'unique_bounded_reference_rows')
    artifacts = bundle['artifacts']
    NET.require(len(artifacts) <= 100, 'bounded_artifacts')
    expected_refs = {identity for identity, row in artifacts.items()
                     if row['kind'] == 'bpmn_bridge'}
    NET.require(set(cases) == expected_refs, 'complete_reference_cohort')
    results = []
    for identity, artifact in sorted(artifacts.items()):
        record = artifact['prepared']
        result = {'id': identity, 'original_prepared': record}
        if artifact['kind'] == 'bpmn_bridge':
            xml = raw(bound_file(prepared / 'inputs', artifact['input_file']))
            NET.require(digest(xml) == artifact['input_sha256'], 'raw_bpmn_conservation')
        if record.get('status') != 'net_saved':
            result['status'] = 'original_admission_refusal_retained'
        else:
            net_bytes = raw(bound_file(prepared / 'nets', record['net_file']))
            graph_bytes = raw(bound_file(prepared / 'graphs', record['graph_file']))
            map_bytes = raw(bound_file(prepared / 'maps', record['map_file']))
            NET.require(digest(net_bytes) == record['net_sha256'] and
                        digest(graph_bytes) == record['graph_sha256'] and
                        digest(map_bytes) == record['map_sha256'], 'saved_artifact_hashes')
            wrapper = json.loads(graph_bytes)
            if record.get('admission_status') != 'admitted':
                NET.require(wrapper.get('status') != 'admitted', 'admission_status_conservation')
                result['status'] = 'original_net_state_refusal_retained'
            else:
                result['rust_conservation'] = NET.validate(net_bytes, wrapper)
                result['status'] = 'exact_saved_net_graph_conservation'
                if artifact['kind'] == 'bpmn_bridge':
                    row = cases[identity]
                    NET.require(row['status'] == 'converted', 'required_reference_conversion_failed')
                    ref_net = raw(reference / (identity + '.net.json'))
                    ref_graph = raw(reference / (identity + '.graph.json'))
                    NET.require(digest(ref_net) == row['net_sha256'] and
                                digest(ref_graph) == row['graph_sha256'], 'reference_artifact_hashes')
                    graph = json.loads(ref_graph)
                    result['reference_conservation'] = NET.validate(ref_net, graph)
                    result['language'] = LANGUAGE.compare(wrapper['graph'], graph)
                    NET.require(result['language']['status'] == 'equivalent',
                                'complete_observable_accepting_language_disagreement')
                    result['status'] = 'exact_conservation_and_complete_language_equivalence'
        if identity in cases and record.get('admission_status') != 'admitted':
            NET.require(cases[identity]['status'] == 'not_executed_rust_admission_refused' and
                        cases[identity]['original_rust_prepared'] == record,
                        'reference_refusal_conservation')
        results.append(result)
    return {'schema_version': 1, 'status': 'ALL_SAVED_CONSERVATION_LANGUAGE_AND_REFUSAL_CHECKS_PASSED',
            'bundle_sha256': digest(bundle_bytes), 'reference_conversions_sha256': digest(reference_bytes),
            'corpus_sha256': EXPECTED_CORPUS, 'cases': results,
            'no_metric_or_miner_execution': True, 'not_independent_acceptance': True,
            'checker_sources': {str(path.relative_to(ROOT)).replace('\\', '/'): digest(raw(path))
                                for path in [Path(__file__), ROOT / 'tools/oracle/validate-quality-net-graph.py',
                                             ROOT / 'tools/oracle/compare-quality-graphs.py']}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prepared', type=Path)
    parser.add_argument('reference', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = validate(args.prepared, args.reference)
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')


if __name__ == '__main__':
    main()
