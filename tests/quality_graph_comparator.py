"""Independent automata regressions; no BPMN/miner/metric execution."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'comparator', Path(__file__).resolve().parents[1] / 'tools/oracle/compare-quality-graphs.py')
comparator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparator)


def graph(size, final, edges):
    transitions = {identity: {'id': identity, 'label': label}
                   for _, _, identity, label in edges}
    return {'schema_version': 1, 'net_sha256': '0' * 64, 'places': ['place'],
            'transitions': list(transitions.values()), 'initial_state': 0,
            'final_states': final, 'states': [[n] for n in range(size)],
            'edges': [{'from': source, 'to': target, 'transition': identity, 'label': label}
                      for source, target, identity, label in edges]}


class GraphEquivalence(unittest.TestCase):
    def test_infinite_loop_and_extra_silent_cycle_are_equivalent(self):
        left = graph(2, [1], [(0, 0, 'a', 'A'), (0, 1, 'b', 'B')])
        right = graph(4, [2], [(0, 1, 'tau0', None), (1, 3, 'tau1', None),
                               (3, 1, 'tau2', None), (1, 1, 'a', 'A'),
                               (1, 2, 'b', 'B')])
        self.assertEqual(comparator.compare(left, right)['status'], 'equivalent')

    def test_all_duplicate_label_branches_required(self):
        left = graph(4, [3], [(0, 1, 'a1', 'A'), (0, 2, 'a2', 'A'),
                              (1, 3, 'b', 'B'), (2, 3, 'c', 'C')])
        right = graph(3, [2], [(0, 1, 'a', 'A'), (1, 2, 'b', 'B'), (1, 2, 'c', 'C')])
        self.assertEqual(comparator.compare(left, right)['status'], 'equivalent')
        missing = graph(3, [2], [(0, 1, 'a', 'A'), (1, 2, 'b', 'B')])
        result = comparator.compare(left, missing)
        self.assertEqual(result['status'], 'not_equivalent')
        self.assertEqual(result['witness'], ['A', 'C'])
        self.assertTrue(result['left_accepts'])
        self.assertFalse(result['right_accepts'])

    def test_empty_word_acceptance_is_not_ignored(self):
        yes = graph(1, [0], [])
        no = graph(1, [], [])
        result = comparator.compare(yes, no)
        self.assertEqual(result['status'], 'not_equivalent')
        self.assertEqual(result['witness'], [])

    def test_search_cap_never_returns_equivalent(self):
        item = graph(2, [1], [(0, 1, 'a', 'A')])
        self.assertEqual(comparator.compare(item, item, 1),
                         {'status': 'inconclusive', 'reason': 'equivalence_subset_pair_budget',
                          'visited_subset_pairs': 1, 'limit': 1})

    def test_long_counterexample_beyond_short_trace_sampling(self):
        edges = [(i, i + 1, f't{i}', 'A') for i in range(20)]
        left = graph(21, [20], edges)
        right = graph(21, [19], edges)
        result = comparator.compare(left, right)
        self.assertEqual(result['status'], 'not_equivalent')
        self.assertEqual(result['witness'], ['A'] * 19)

    def test_labels_remain_atomic_including_unicode_and_delimiters(self):
        left = graph(2, [1], [(0, 1, 'a', 'Тексеру,@@<&>')])
        right = graph(2, [1], [(0, 1, 'a', 'Тексеру,@@<&>')])
        before = copy.deepcopy((left, right))
        self.assertEqual(comparator.compare(left, right)['status'], 'equivalent')
        self.assertEqual((left, right), before)

    def test_label_and_reachability_corruption_refused(self):
        item = graph(2, [1], [(0, 1, 'a', 'A')])
        altered = copy.deepcopy(item)
        altered['edges'][0]['label'] = 'B'
        with self.assertRaisesRegex(ValueError, 'edge_label_conservation'):
            comparator.compare(item, altered)
        altered = copy.deepcopy(item)
        altered['states'].append([2])
        with self.assertRaisesRegex(ValueError, 'unreachable'):
            comparator.compare(item, altered)


if __name__ == '__main__':
    unittest.main()
