"""Independent opaque-boundary controls; no producer or engine imports."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('independent_projection', Path(__file__).resolve().parents[1] / 'tools/sprint20/verify-public-projection.py')
A = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(A)


class OpaqueEvidence(unittest.TestCase):
    def test_genuine_refusal_input_remains_bytes_not_metadata(self):
        malformed = b'{"places":{},"places":{}}'
        with self.assertRaises(ValueError): A.parse(malformed)
        row = {'source_path': 'conversions/inputs/duplicate-key.json', 'representation': 'opaque_scientific_bytes', 'transformations': []}
        A.compare_opaque(row, malformed, malformed)
        for bad in (b'{"places":{}}', malformed + b' '):
            with self.assertRaises(ValueError): A.compare_opaque(row, malformed, bad)
        with self.assertRaises(ValueError): A.compare_opaque({**row, 'transformations': [{'kind': 'path_alias'}]}, malformed, malformed)

    def test_opaque_scope_cannot_hide_metadata_or_arbitrary_payload_name(self):
        positive = ['conversions/inputs/a.json', 'conversion-boundaries/inputs/over-limit.json',
                    'conversions/cases/P01/inverse/payload.json', 'conversions/cases/P02/forward/payload.json',
                    'conversion-boundaries/cases/novel-json/payload.json']
        negative = ['miner-performance/inputs/a.json', 'conversions/index.json', 'conversions/cases/P01/forward/report.json',
                    'miner-performance/payload.json', 'conversions/payload.json', 'conversions/cases/P01/metadata/payload.json',
                    'conversion-boundaries/environment/payload.json']
        for path in positive: self.assertTrue(A.opaque_scientific(path), path)
        for path in negative:
            self.assertFalse(A.opaque_scientific(path), path)
            with self.assertRaises(ValueError):
                A.compare_opaque({'source_path': path, 'representation': 'opaque_scientific_bytes', 'transformations': []}, b'{}', b'{}')


if __name__ == '__main__':
    unittest.main()
