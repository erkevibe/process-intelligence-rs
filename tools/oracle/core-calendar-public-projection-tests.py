"""Pure publication encoder tests. No generator main, native process or engine."""
import importlib.util
import unittest
from pathlib import Path
import sys

class NumericLexemes(unittest.TestCase):
    def test_exact_original_tokens(self):
        path = Path(__file__).with_name('core-calendar-public-projection.py')
        spec = importlib.util.spec_from_file_location('calendar_public_projection_pure_test', path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        raw = b'{"high":9223372036854775807,"low":-9223372036854775808,"wide":9007199254740993,"float":-0.0,"exp":1.2300e+07,"zero":-0}'
        before = module.decode(raw)
        after = module.decode(module.encode(before).encode('utf-8'))
        expected = ['9223372036854775807','-9223372036854775808','9007199254740993','-0.0','1.2300e+07','-0']
        self.assertEqual(module.number_tokens(before), expected)
        self.assertEqual(module.number_tokens(after), expected)

if __name__ == '__main__':
    unittest.main()
