"""Typed same-saved-net comparison with all eight original miner outcomes retained."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


HERE = Path(__file__).resolve().parent
COMPARISON = module('base_quality_comparison', HERE / 'compare-quality-results.py')
PREPARATION = module('miner_preparation_conservation', HERE / 'validate-miner-preparation.py')


def read(path):
    return PREPARATION.NET.read(path)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def compare(rust_raw, ref_raw, prepared, conversion):
    rust, ref = json.loads(rust_raw), json.loads(ref_raw)
    corpus = json.loads(read(prepared / 'inputs/corpus.json'))
    bundle_raw = read(prepared / 'bundle.json')
    bundle = json.loads(bundle_raw)
    require = COMPARISON.require
    require(rust['cohort_sha256'] == ref['cohort_sha256'] == PREPARATION.EXPECTED,
            'fixed_eight_row_cohort')
    require(rust['bundle_sha256'] == ref['bundle_sha256'] == sha(bundle_raw), 'same_saved_bundle')
    require(sha(read(prepared / 'inputs/corpus.json')) == PREPARATION.EXPECTED,
            'original_cohort_bytes')
    rc = COMPARISON.index(rust['cases'], lambda row: row['id'])
    fc = COMPARISON.index(ref['cases'], lambda row: row['id'])
    ids = {case['id'] for case in corpus['cases']}
    require(set(rc) == set(fc) == ids and len(ids) == 8, 'complete_all_eight_results')
    admission = PREPARATION.validate(prepared, conversion)
    results = []
    for case in corpus['cases']:
        identity = case['id']
        left, right = rc[identity], fc[identity]
        result = {'id': identity, 'training_only': True, 'fitness': None,
                  'precision': None, 'simplicity': None}
        record = bundle['artifacts'][identity]['prepared']
        if left['result']['status'] != 'admitted':
            require(left['result'] == record and 'groups' not in right, 'no_nonadmitted_scalars')
            if identity == 'self-loop':
                require(right['status'] == 'raw_compatibility_refused' and
                        right['reason'] == 'quality_unsupported_standard_loop_before_both_converters',
                        'reference_raw_loop_refusal')
            else:
                require(identity == 'empty-log' and right['status'] == 'not_executed_rust_admission_refused'
                        and right['original_rust_prepared'] == record, 'carried_empty_exception')
            result.update(status=left['result']['status'], original_result=record,
                          original_reference_result=right)
        else:
            require(left['net_sha256'] == right['net_sha256'] == record['net_sha256'],
                    'same_actual_saved_net')
            lg, rg = left['result']['groups'], right['groups']
            require(len(lg) == len(rg) == 1 and lg[0]['group'] == rg[0]['group'] == 'training_log'
                    and lg[0]['input'] == rg[0]['input'] == case['source_input']['training_log']
                    and case['source_input']['heldout_log'] is None, 'exact_original_training_only')
            net_bytes = PREPARATION.member(prepared / 'nets', record['net_file'], record['net_sha256'])
            PREPARATION.NET.validate(net_bytes, left['result']['graph'])
            checked = COMPARISON.compare_metrics(lg[0]['metrics'], rg[0]['result'], left['result']['graph'])
            require(checked['status'] == 'exact_components_and_scalars_agree_paths_need_independent_audit',
                    'unexpected_reference_inconclusive')
            result.update(status='same_saved_net_metric_components_agree',
                          net_sha256=record['net_sha256'], comparison=checked,
                          fitness=checked.get('fitness_exact'),
                          precision=checked.get('precision_exact'),
                          precision_status=checked['precision_status'],
                          simplicity=checked['simplicity_exact'])
        results.append(result)
    return {'schema_version': 1, 'status': 'ALL_EIGHT_CARRIED_OUTCOMES_AND_SIX_ADMITTED_METRIC_COMPARISONS',
            'cohort_sha256': PREPARATION.EXPECTED, 'bundle_sha256': sha(bundle_raw),
            'raw_result_sha256': [sha(rust_raw), sha(ref_raw)], 'cases': results,
            'preparation_conservation': admission, 'not_new_miner_execution': True,
            'no_heldout_or_generalization_claim': True, 'independent_path_audit_required': True,
            'not_R4_acceptance': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rust', type=Path)
    parser.add_argument('reference', type=Path)
    parser.add_argument('prepared', type=Path)
    parser.add_argument('conversion', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = compare(read(args.rust), read(args.reference), args.prepared, args.conversion)
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')


if __name__ == '__main__':
    main()
