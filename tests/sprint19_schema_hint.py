"""Exact frozen schema-hint source spans and atomic refusal; no metric engine."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'fixtures/quality-schema-hint'
SPEC = importlib.util.spec_from_file_location('schema_hint', ROOT / 'tools/sprint19/schema-hint.py')
HINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HINT)


class SchemaHint(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw = (FIXTURES / 'corpus.json').read_bytes()
        if hashlib.sha256(raw).hexdigest() != '5aefc743c6f12e17d8a3ce1857bc1808334971ca06de6ff09ff158249cc2194a':
            raise AssertionError('frozen_schema_fixture_changed')
        cls.manifest = json.loads(raw)
        cls.original = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in FIXTURES.iterdir() if p.is_file()}

    def tearDown(self):
        self.assertEqual(self.original, {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                        for p in FIXTURES.iterdir() if p.is_file()})

    def test_all_five_positive_exact_bytes_spans_and_semantic_maps(self):
        rows = [row for row in self.manifest['cases'] if row['expected']['projection_status'] == 'projected']
        self.assertEqual(len(rows), 5)
        for row in rows:
            with self.subTest(case=row['id']):
                source = (FIXTURES / row['file']).read_bytes()
                output, report = HINT.project(source)
                expected = row['expected']
                self.assertEqual(output, (FIXTURES / expected['projected_file']).read_bytes())
                self.assertEqual(report['projected_sha256'], expected['projected_sha256'])
                self.assertEqual(report['removed_spans'], expected['spans'])
                self.assertEqual(report['semantic_map'],
                                 json.loads((FIXTURES / expected['semantic_map_file']).read_bytes()))
                restored = bytearray(output)
                for span in expected['spans']:
                    restored[span['byte_start']:span['byte_start']] = span['raw_utf8'].encode()
                self.assertEqual(bytes(restored), source)
                self.assertTrue(report['never_resolve_schema'])
                self.assertTrue(report['strict_projected_reparse_required'])
                if row['id'] == 'H05-real-miner-retains-DI':
                    self.assertIn(b'BPMNLabel', output)

    def test_all_nineteen_negative_categories_no_external_access(self):
        rows = [row for row in self.manifest['cases'] if row['expected']['projection_status'] == 'refused']
        self.assertEqual(len(rows), 19)
        for row in rows:
            with self.subTest(case=row['id']):
                source = (FIXTURES / row['file']).read_bytes()
                with mock.patch('builtins.open', side_effect=AssertionError('external_access_forbidden')):
                    with self.assertRaises(HINT.ProjectionRefused) as raised:
                        HINT.project(source)
                self.assertEqual(raised.exception.category, row['expected']['category'])

    def test_every_negative_cli_is_atomic(self):
        with tempfile.TemporaryDirectory(prefix='schema-hint-test-') as directory:
            for row in self.manifest['cases']:
                if row['expected']['projection_status'] != 'refused':
                    continue
                with self.subTest(case=row['id']):
                    output = Path(directory) / (row['id'] + '.bpmn')
                    report = Path(directory) / (row['id'] + '.json')
                    with mock.patch('sys.argv', ['schema-hint.py', '--input', str(FIXTURES / row['file']),
                                               '--output', str(output), '--report', str(report)]):
                        with self.assertRaises(SystemExit) as raised:
                            HINT.main()
                    self.assertEqual(raised.exception.code, 2)
                    self.assertFalse(output.exists())
                    observed = json.loads(report.read_bytes())
                    self.assertEqual(observed['category'], row['expected']['category'])
                    self.assertEqual(observed['original_sha256'], row['sha256'])
                    self.assertIsNone(observed['projected_sha256'])
                    self.assertTrue(observed['no_partial_projection'])


if __name__ == '__main__':
    unittest.main()
