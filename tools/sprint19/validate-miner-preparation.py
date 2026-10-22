"""Conservation and complete accepting-language checks for all eight carried outcomes."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = '6dac7a9b69d553590f342ed4b836140678a9f2c072cc806119f0ecc48ace208d'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


NET = module('miner_net_conservation', ROOT / 'tools/oracle/validate-quality-net-graph.py')
LANGUAGE = module('miner_complete_language', ROOT / 'tools/oracle/compare-quality-graphs.py')


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def member(directory, name, expected):
    NET.require(isinstance(name, str) and name and '/' not in name and '\\' not in name
                and ':' not in name and name not in {'.', '..'}, 'member_basename')
    value = NET.read(directory / name)
    NET.require(digest(value) == expected.lower(), 'actual_saved_member_hash')
    return value


def validate(prepared, reference):
    bundle_raw = NET.read(prepared / 'bundle.json')
    bundle = json.loads(bundle_raw)
    corpus_raw = NET.read(prepared / 'inputs/corpus.json')
    NET.require(digest(corpus_raw) == bundle['cohort_sha256'] == EXPECTED, 'frozen_cohort')
    corpus = json.loads(corpus_raw)
    conversion_raw = NET.read(reference / 'reference-conversions.json')
    conversion = json.loads(conversion_raw)
    NET.require(conversion['cohort_sha256'] == EXPECTED and
                conversion['bundle_sha256'] == digest(bundle_raw), 'same_prepared_reference_bundle')
    refs = {row['id']: row for row in conversion['cases']}
    ids = {row['id'] for row in corpus['cases']}
    NET.require(len(ids) == len(corpus['cases']) == len(refs) == len(conversion['cases']) == 8
                and set(bundle['artifacts']) == set(refs) == ids, 'all_eight_outcomes')
    results = []
    for case in corpus['cases']:
        identity = case['id']
        NET.require('/' not in identity and '\\' not in identity and ':' not in identity,
                    'cohort_identity')
        artifact, ref = bundle['artifacts'][identity], refs[identity]
        record = artifact['prepared']
        NET.require(artifact['source_input'] == case['source_input'] and
                    artifact['carried_actual_outcome'] == case['carried_actual_outcome'],
                    'original_training_and_carried_outcome_conservation')
        member(prepared / 'inputs', identity + '.xes', case['source_input']['sha256'])
        NET.require(case['source_input']['heldout_log'] is None, 'no_invented_heldout')
        result = {'id': identity, 'prepared_status': record['status'],
                  'original_rust_prepared': record, 'reference_status': ref['status']}
        NET.require(ref['original_rust_prepared'] == record, 'reference_original_status_conservation')
        if case['raw_bpmn'] is not None:
            member(prepared / 'inputs', identity + '.raw.bpmn', case['raw_bpmn']['sha256'])
        if record.get('admission_status') == 'admitted':
            NET.require(ref['status'] == 'converted_original_raw_xml' and
                        ref['original_sha256'] == case['raw_bpmn']['sha256'], 'reference_original_xml')
            raw = member(prepared / 'nets', record['net_file'], record['net_sha256'])
            graph_raw = member(prepared / 'graphs', record['graph_file'], record['graph_sha256'])
            member(prepared / 'maps', record['map_file'], record['map_sha256'])
            graph = json.loads(graph_raw)
            ref_net = member(reference, ref['net_file'], ref['net_sha256'])
            ref_graph = json.loads(member(reference, ref['graph_file'], ref['graph_sha256']))
            result['rust_conservation'] = NET.validate(raw, graph)
            result['reference_conservation'] = NET.validate(ref_net, ref_graph)
            result['language'] = LANGUAGE.compare(graph['graph'], ref_graph)
            NET.require(result['language']['status'] == 'equivalent', 'complete_language_disagreement')
            result['status'] = 'exact_saved_conservation_and_original_xml_language_equivalence'
        elif identity == 'self-loop':
            NET.require(record['reason'] == 'quality_unsupported_standard_loop_before_both_converters'
                        and ref['status'] == 'reference_conversion_refused'
                        and ref['reason'] == 'quality_unsupported_standard_loop_before_both_converters'
                        and ref['exception_class'] == 'ProjectionRefused', 'both_raw_loop_refusals')
            result['status'] = 'unsupported_behavior_preserved_no_scalar'
        elif identity == 'empty-log':
            NET.require(record['status'] == 'carried_algorithm_exception' and
                        ref['status'] == 'carried_algorithm_exception', 'carried_empty_log_exception')
            result['status'] = 'historical_algorithm_exception_preserved_no_scalar'
        else:
            result.update(status='unexpected_admission_failure', reference=ref)
            raise ValueError('unexpected_cohort_admission_failure:' + identity)
        results.append(result)
    return {'schema_version': 1, 'status': 'COMPLETE_EIGHT_OUTCOME_CONSERVATION_AND_ADMITTED_LANGUAGE_CHECKS',
            'cohort_sha256': EXPECTED, 'bundle_sha256': digest(bundle_raw),
            'reference_conversions_sha256': digest(conversion_raw), 'cases': results,
            'no_metric_or_new_miner_execution': True, 'not_whole_R4_acceptance': True}


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
