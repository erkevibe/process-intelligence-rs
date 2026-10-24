"""Frozen DI byte-span/namespace/refusal tests, independent of any metric engine."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'fixtures/quality-di'
SPEC = importlib.util.spec_from_file_location('quality_di', ROOT / 'tools/sprint19/quality-di.py')
DI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DI)


class QualityDI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw_manifest = (FIXTURES / 'corpus.json').read_bytes()
        if hashlib.sha256(cls.raw_manifest).hexdigest() != 'ade9d7ddcb689d946bbee8110024302fe50faad88f0423228a4ccdccb532f3f5':
            raise AssertionError('frozen_DI_manifest_changed')
        cls.manifest = json.loads(cls.raw_manifest)
        cls.original_files = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in FIXTURES.iterdir() if path.is_file()}

    def tearDown(self):
        self.assertEqual(self.original_files,
                         {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in FIXTURES.iterdir() if path.is_file()})

    def test_all_five_positive_exact_spans_and_projected_bytes(self):
        positives = [case for case in self.manifest['cases']
                     if case['expected']['projection_status'] == 'projected']
        self.assertEqual(len(positives), 5)
        for case in positives:
            with self.subTest(case=case['id']):
                raw = (FIXTURES / case['file']).read_bytes()
                expected = case['expected']
                self.assertEqual(hashlib.sha256(raw).hexdigest(), case['sha256'])
                projected, report = DI.project(raw)
                self.assertEqual(projected, (FIXTURES / expected['projected_file']).read_bytes())
                self.assertEqual(report['projected_sha256'], expected['projected_sha256'])
                self.assertEqual(report['removed_spans'], expected['spans'])
                self.assertEqual(report['semantic_map'],
                                 json.loads((FIXTURES / expected['semantic_map_file']).read_bytes()))
                self.assertEqual(projected,
                                 (FIXTURES / expected['complete_observable_automata_equal_to']).read_bytes())
                # Re-adding exact removed byte spans reconstructs every original byte.
                reconstructed = bytearray(projected)
                for span in expected['spans']:
                    reconstructed[span['byte_start']:span['byte_start']] = span['raw_utf8'].encode()
                self.assertEqual(bytes(reconstructed), raw)
                self.assertTrue(report['strict_projected_reparse_required'])
                self.assertTrue(report['original_product_import_not_claimed'])

    def test_all_twenty_negative_inputs_refuse_without_returned_projection(self):
        negatives = [case for case in self.manifest['cases']
                     if case['expected']['projection_status'] == 'refused']
        self.assertEqual(len(negatives), 20)
        for case in negatives:
            with self.subTest(case=case['id']):
                raw = (FIXTURES / case['file']).read_bytes()
                with mock.patch('builtins.open', side_effect=AssertionError('external_access_forbidden')):
                    with self.assertRaises(DI.ProjectionRefused) as raised:
                        DI.project(raw)
                self.assertEqual(raised.exception.category, case['expected']['category'])

    def test_all_refused_cli_cases_create_report_only_no_partial_projection(self):
        with tempfile.TemporaryDirectory(prefix='quality-di-test-') as directory:
            for case in self.manifest['cases']:
                if case['expected']['projection_status'] != 'refused':
                    continue
                with self.subTest(case=case['id']):
                    output = Path(directory) / (case['id'] + '.projected.bpmn')
                    report = Path(directory) / (case['id'] + '.report.json')
                    argv = ['quality-di.py', '--input', str(FIXTURES / case['file']),
                            '--output', str(output), '--report', str(report)]
                    with mock.patch('sys.argv', argv):
                        with self.assertRaises(SystemExit) as raised:
                            DI.main()
                    self.assertEqual(raised.exception.code, 2)
                    self.assertFalse(output.exists())
                    observed = json.loads(report.read_bytes())
                    self.assertEqual(observed['projection_status'], 'refused')
                    self.assertEqual(observed['category'], case['expected']['category'])
                    self.assertEqual(observed['original_sha256'], case['sha256'])
                    self.assertIsNone(observed['projected_sha256'])
                    self.assertTrue(observed['no_partial_projection'])

    def test_annotation_free_documents_stay_byte_identical(self):
        for row in self.manifest['annotation_free']:
            with self.subTest(row=row['id']):
                original = (FIXTURES / row['file']).read_bytes()
                projected, report = DI.project(original)
                self.assertEqual(projected, original)
                self.assertEqual(report['removed_spans'], [])
                self.assertEqual(report['original_sha256'], report['projected_sha256'])


if __name__ == '__main__':
    unittest.main()
