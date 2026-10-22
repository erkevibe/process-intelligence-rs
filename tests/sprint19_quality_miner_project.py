"""Pure frozen projection/provenance tests; no model or metric engine."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('miner_projection', ROOT / 'tools/sprint19/quality-miner-project.py')
project = importlib.util.module_from_spec(spec)
spec.loader.exec_module(project)


class ProjectionTests(unittest.TestCase):
    def test_eight_original_outcomes_and_exact_two_stage_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'projection'
            project.prepare(ROOT / 'fixtures/quality-miner/corpus.json', output)
            bundle = json.loads((output / 'projection.json').read_bytes())
            self.assertEqual(len(bundle['cases']), 8)
            rows = {row['id']: row for row in bundle['cases']}
            self.assertEqual(rows['empty-log']['status'], 'carried_algorithm_exception')
            self.assertEqual(rows['self-loop']['category'],
                             'quality_unsupported_standard_loop_before_both_converters')
            self.assertTrue(rows['self-loop']['no_partial_projection'])
            for row in bundle['cases']:
                if row['status'] != 'projected_pending_strict_prepare':
                    continue
                raw = (output / 'inputs' / row['raw_file']).read_bytes()
                hint = (output / 'projection' / row['hint_file']).read_bytes()
                projected = (output / 'projection' / row['projected_file']).read_bytes()
                first = json.loads((output / 'projection' / row['hint_report_file']).read_bytes())
                second = json.loads((output / 'projection' / row['di_report_file']).read_bytes())
                self.assertEqual(project.reconstruct(raw, first), hint)
                self.assertEqual(project.reconstruct(hint, second), projected)
                self.assertEqual(first['semantic_map'], second['semantic_map'])
                broken = json.loads(json.dumps(first))
                broken['removed_spans'][0]['byte_length'] += 1
                with self.assertRaises(ValueError):
                    project.reconstruct(raw, broken)

    def test_training_lineage_rejects_changed_frequency_and_order(self):
        corpus = json.loads((ROOT / 'fixtures/quality-miner/corpus.json').read_bytes())
        case = next(row for row in corpus['cases'] if row['id'] == 'linear')
        source = case['source_input']
        raw = (ROOT / 'fixtures/quality-miner' / source['file']).read_bytes()
        project.verify_traces(raw, source)
        changed = json.loads(json.dumps(source))
        changed['training_log'][0]['frequency'] += 1
        with self.assertRaises(ValueError):
            project.verify_traces(raw, changed)
        changed = json.loads(json.dumps(source))
        changed['traces'][0]['sequence'].reverse()
        with self.assertRaises(ValueError):
            project.verify_traces(raw, changed)


if __name__ == '__main__':
    unittest.main()
