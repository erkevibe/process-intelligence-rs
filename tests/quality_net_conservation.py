"""Net/graph conservation and semantic tamper regressions, no external engines."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'validator', Path(__file__).resolve().parents[1] / 'tools/oracle/validate-quality-net-graph.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def sample():
    net = {'places': {'p': {'id': 'p'}, 'q': {'id': 'q'}},
           'transitions': {'a': {'id': 'a', 'label': 'A'},
                           'back': {'id': 'back', 'label': None}},
           'arcs': [{'from_to': {'type': kind, 'nodes': nodes}, 'weight': weight}
                    for kind, nodes, weight in [
                        ('PlaceTransition', ['p', 'a'], 2),
                        ('TransitionPlace', ['a', 'q'], 1),
                        ('PlaceTransition', ['q', 'back'], 1),
                        ('TransitionPlace', ['back', 'p'], 2)]],
           'initial_marking': {'p': 2}, 'final_markings': [{'q': 1}]}
    raw = json.dumps(net).encode()
    graph = {'schema_version': 1, 'net_sha256': hashlib.sha256(raw).hexdigest(),
             'places': ['p', 'q'], 'transitions': [{'id': 'a', 'label': 'A'},
                                                {'id': 'back', 'label': None}],
             'initial_state': 0, 'final_states': [1], 'states': [[2, 0], [0, 1]],
             'edges': [{'from': 0, 'to': 1, 'transition': 'a', 'label': 'A'},
                       {'from': 1, 'to': 0, 'transition': 'back', 'label': None}]}
    return raw, graph


class Conservation(unittest.TestCase):
    def test_weighted_cycle_and_admission_wrapper(self):
        raw, graph = sample()
        result = validator.validate(raw, {'status': 'admitted', 'graph': graph})
        self.assertEqual((result['states'], result['edges']), (2, 2))

    def test_missing_enabled_transition_and_added_edge_refused(self):
        raw, original = sample()
        for edges in [original['edges'][:1], original['edges'] + [
                {'from': 0, 'to': 0, 'transition': 'a', 'label': 'A'}]]:
            graph = copy.deepcopy(original)
            graph['edges'] = edges
            with self.assertRaisesRegex(ValueError, 'firing_edges'):
                validator.validate(raw, graph)

    def test_equal_language_but_relabelled_transition_refused(self):
        raw, graph = sample()
        graph['edges'][0]['transition'] = 'back'
        with self.assertRaisesRegex(ValueError, 'firing_edges'):
            validator.validate(raw, graph)

    def test_unreachable_state_and_changed_final_refused(self):
        raw, original = sample()
        graph = copy.deepcopy(original)
        graph['states'].append([1, 0])
        with self.assertRaisesRegex(ValueError, 'unreachable'):
            validator.validate(raw, graph)
        graph = copy.deepcopy(original)
        graph['final_states'] = [0]
        with self.assertRaisesRegex(ValueError, 'final_marking'):
            validator.validate(raw, graph)

    def test_hash_and_arc_weight_change_refused(self):
        raw, graph = sample()
        with self.assertRaisesRegex(ValueError, 'exact_net_hash'):
            validator.validate(raw + b' ', graph)
        changed = json.loads(raw)
        changed['arcs'][0]['weight'] = 1
        altered = json.dumps(changed).encode()
        graph['net_sha256'] = hashlib.sha256(altered).hexdigest()
        with self.assertRaisesRegex(ValueError, 'successor_missing'):
            validator.validate(altered, graph)


if __name__ == '__main__':
    unittest.main()
