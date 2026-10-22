"""Lossless typed comparison of separate Rust/PM4Py saved-net metric runs.

Scalar agreement does not replace independent executable alignment/prefix checks.
Failed frozen hypotheses are emitted separately and never rewritten as passes.
"""
import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import importlib.util
import json
import math
from pathlib import Path


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def same_number(value, expected, reason):
    require(type(value) in (int, float) and math.isfinite(value) and
            abs(value - float(Fraction(expected))) <= 1e-9, reason)


def index(rows, key):
    result = {key(row): row for row in rows}
    require(len(result) == len(rows), 'duplicate_result_key')
    return result


def compare_metrics(rust, reference, graph):
    if reference.get('status') == 'reference_inconclusive':
        return {'status': 'reference_inconclusive_no_numeric_agreement_credit',
                'reference': reference}
    output = {}
    left, right = rust['fitness'], reference['fitness']
    require(left['status'] == right['status'], 'fitness_status')
    output['fitness_status'] = left['status']
    if left['status'] == 'measured':
        lc = left['integer_components']
        require(lc['weighted_total_cost'] == right['total_cost'] and
                lc['log_denominator'] == right['denominator'] and
                lc['empty_cost'] == right['empty_alignment']['cost'], 'fitness_integer_components')
        for lkey, rkey in [('log_fitness', 'log_fitness'), ('average_fitness', 'average_trace_fitness'),
                            ('perfectly_fitting_frac', 'perfectly_fitting_frac')]:
            same_number(left['fitness'][lkey], right[rkey], 'fitness_' + lkey)
        la = index(left['alignments'], lambda row: tuple(row['activities']))
        ra = index(right['alignments'], lambda row: tuple(row['activities']))
        require(set(la) == set(ra), 'complete_alignment_variant_set')
        for activities, row in la.items():
            require(row['frequency'] == ra[activities]['frequency'] and
                    row['result']['Ok']['cost'] == ra[activities]['result']['cost'],
                    'variant_frequency_or_optimal_cost')
        output['fitness_exact'] = {key: right[key] for key in
                                   ['total_cost', 'denominator', 'log_fitness',
                                    'average_trace_fitness', 'perfectly_fitting_frac']}
    left, right = rust['precision'], reference['precision']
    require(left['status'] == right['status'], 'precision_status')
    output['precision_status'] = left['status']
    if left['status'] in {'measured', 'not_applicable_no_activated_labels'}:
        require(left['activated_weight'] == right['activated_weight'] and
                left['escaping_weight'] == right['escaping_weight'], 'precision_weighted_components')
        if left['status'] == 'measured':
            require(Fraction(left['numerator'], left['denominator']) == Fraction(right['rational']),
                    'precision_exact_fraction')
            same_number(left['scalar'], right['rational'], 'precision_scalar')
            same_number(right['scalar'], right['rational'], 'reference_precision_scalar')
            lp = index(left['prefixes'], lambda row: tuple(row['prefix']))
            rp = index(right['prefixes'], lambda row: tuple(row['prefix']))
            initial = dict(right['empty_prefix'], prefix=[], escaping_labels=sorted(
                set(right['empty_prefix']['activated_labels']) -
                set(right['empty_prefix']['observed_next_labels'])))
            rp[()] = initial
            require(set(lp) == set(rp), 'complete_prefix_set')
            for prefix, row in lp.items():
                refrow = rp[prefix]
                require(row['weight'] == refrow['weight'], 'prefix_occurrence_weight')
                for field in ['activated_labels', 'observed_next_labels', 'escaping_labels']:
                    require(sorted(row[field]) == sorted(refrow[field]), 'prefix_' + field)
                if prefix:
                    lm = {tuple(graph['states'][state]) for state in row['stop_markings']}
                    rm = {tuple(marking.get(place, 0) for place in graph['places'])
                          for marking in refrow['stop_markings']}
                    require(lm == rm, 'all_minimum_tau_stop_markings')
            output['precision_exact'] = right['rational']
        else:
            require(left['scalar'] is None and right['scalar'] is None, 'no_activated_not_scalar_one')
    elif left['status'] == 'requires_fitting_log':
        require(left['scalar'] is None and right['scalar'] is None and
                left['nonfitting_trace_frequency'] == right['nonfitting_trace_frequency'],
                'full_nonfitting_frequency_no_survivor_precision')
    left, right = rust['simplicity'], reference['simplicity']
    require(left['status'] == right['status'] == 'measured', 'simplicity_status')
    exact = Fraction(left['numerator'], left['denominator'])
    same_number(right['scalar'], exact, 'simplicity_scalar')
    if 'places' in right:
        require(all(left[key] == right[key] for key in ['places', 'transitions', 'arcs']),
                'simplicity_exact_structure')
    output['simplicity_exact'] = str(exact)
    output['status'] = 'exact_components_and_scalars_agree_paths_need_independent_audit'
    return output


def compare(rust, reference, equivalence_caps=None):
    require(rust['bundle_sha256'] == reference['bundle_sha256'] and
            rust['corpus_sha256'] == reference['corpus_sha256'], 'same_bundle_and_corpus')
    refs = index(reference['cases'], lambda row: (row['id'], row['artifact_id']))
    expected_keys = {(case['id'], row['artifact_id']) for case in rust['cases']
                     for row in case['measurements']}
    require(set(refs) == expected_keys, 'all_result_rows_preserved')
    results, hypotheses = [], []
    for case in rust['cases']:
        for row in case['measurements']:
            key = (case['id'], row['artifact_id'])
            ref = refs[key]
            result = {'id': key[0], 'artifact_id': key[1]}
            if row['result']['status'] != 'admitted':
                result.update(status='original_admission_or_lower_cap_result_retained',
                              rust_result=row['result'], reference_result=ref)
            else:
                require(row['net_sha256'] == ref['net_sha256'], 'same_actual_saved_net')
                rg = index(ref['groups'], lambda group: group['group'])
                lg = index(row['result']['groups'], lambda group: group['group'])
                require(set(lg) == set(rg) == {'training_log', 'heldout_log'}, 'both_log_groups_required')
                result.update(status='compared', net_sha256=row['net_sha256'], groups=[])
                for group, measured in lg.items():
                    require(measured['input'] == rg[group]['input'], 'same_complete_log')
                    compared = compare_metrics(measured['metrics'], rg[group]['result'], row['result']['graph'])
                    if compared['status'] == 'reference_inconclusive_no_numeric_agreement_credit':
                        require(case['frozen_input_and_hypothesis'].get('test_only_lower_caps'),
                                'unexpected_reference_failure')
                    result['groups'].append({'group': group, 'comparison': compared})
            frozen = case['frozen_input_and_hypothesis']['expected']
            # Preserve original negative reason predictions even when a different
            # valid safety guard or coarser unchanged parser code fires first.
            if 'reason' in frozen:
                actual = row['result'].get('reason')
                reason_source = 'admission'
                if row['result']['status'] == 'admitted':
                    reason_source = 'heldout_precision'
                    heldout = next(group for group in row['result']['groups']
                                   if group['group'] == 'heldout_log')
                    actual = heldout['metrics']['precision'].get('reason')
                if 'equivalence_subset_pairs' in case['frozen_input_and_hypothesis'].get('test_only_lower_caps', {}):
                    reason_source = 'separate_actual_complete_graph_equivalence_cap'
                    actual = (equivalence_caps or {}).get(key[0], {}).get('reason')
                hypotheses.append({'id': key[0], 'artifact_id': key[1], 'field': 'reason',
                                   'expected': frozen['reason'], 'actual': actual,
                                   'source': reason_source,
                                   'passed': None if actual is None else frozen['reason'] == actual})
            results.append(result)
    return {'schema_version': 1, 'status': 'TYPED_CROSS_ENGINE_COMPARISON_COMPLETED_NOT_ACCEPTANCE',
            'corpus_sha256': rust['corpus_sha256'], 'bundle_sha256': rust['bundle_sha256'],
            'artifact_case_rows': len(results), 'results': results, 'negative_reason_hypotheses': hypotheses,
            'negative_reason_failures': sum(row['passed'] is False for row in hypotheses),
            'negative_reason_not_executed': sum(row['passed'] is None for row in hypotheses),
            'separate_equivalence_cap_checks': equivalence_caps or {},
            'independent_path_optimality_and_full_hypothesis_audit_required': True,
            'group_status_counts': dict(Counter(group['comparison']['status'] for row in results
                                                for group in row.get('groups', [])))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rust', type=Path)
    parser.add_argument('reference', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--prepared', type=Path)
    parser.add_argument('--reference-conversion', type=Path)
    args = parser.parse_args()
    inputs = []
    for path in [args.rust, args.reference]:
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024,
                'input_type_or_size')
        inputs.append(path.read_bytes())
    rust, reference = (json.loads(raw) for raw in inputs)
    caps = {}
    for case in rust['cases']:
        limit = case['frozen_input_and_hypothesis'].get('test_only_lower_caps', {}).get('equivalence_subset_pairs')
        if limit is None:
            continue
        require(args.prepared is not None and args.reference_conversion is not None,
                'separate_equivalence_cap_graphs_required')
        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location('quality_equivalence', root / 'tools/oracle/compare-quality-graphs.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for row in case['measurements']:
            identity = row['artifact_id']
            require('/' not in identity and '\\' not in identity and ':' not in identity,
                    'artifact_identity')
            left_bytes = (args.prepared / 'graphs' / (identity + '.graph.json')).read_bytes()
            right_bytes = (args.reference_conversion / (identity + '.graph.json')).read_bytes()
            left, right = json.loads(left_bytes)['graph'], json.loads(right_bytes)
            require(left == row['result']['graph'], 'exact_actual_candidate_graph_for_cap')
            actual = module.compare(left, right, limit)
            caps[case['id']] = {**actual, 'max_subset_pairs': limit,
                                'graph_sha256': [hashlib.sha256(left_bytes).hexdigest(),
                                                 hashlib.sha256(right_bytes).hexdigest()],
                                'checker_sha256': hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest()}
    result = compare(rust, reference, caps)
    result['raw_result_sha256'] = [hashlib.sha256(raw).hexdigest() for raw in inputs]
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')


if __name__ == '__main__':
    main()
