"""Tiny real-file negative controls for the portable evidence manifest verifier."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'tools/sprint20/verify-evidence-manifest.py'
SPEC = importlib.util.spec_from_file_location('s20_manifest_verifier', SOURCE)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class EvidenceManifest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s20-manifest-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'evidence'
        self.root.mkdir()
        (self.root / 'nested').mkdir()
        (self.root / 'one.bin').write_bytes(b'first\x00payload')
        (self.root / 'nested/two.txt').write_bytes(b'second\n')
        rows = []
        for name in ('one.bin', 'nested/two.txt'):
            raw = (self.root / name).read_bytes()
            rows.append({'path': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
        self.manifest = {'schema_version': 1, 'file_count': 2,
                         'total_bytes': sum(r['bytes'] for r in rows), 'files': rows}
        self.write()

    def write(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest), encoding='utf-8')

    def refuse(self, reason):
        with self.assertRaisesRegex(ValueError, reason):
            VERIFY.verify(self.root)

    def test_complete_tiny_actual_tree(self):
        result = VERIFY.verify(self.root)
        self.assertEqual(result['status'], 'COMPLETE_EVIDENCE_BYTES_VERIFIED')
        self.assertEqual(result['files'], 2)
        self.assertEqual(result['bytes'], self.manifest['total_bytes'])

    def test_same_length_byte_flip(self):
        path = self.root / 'one.bin'
        raw = bytearray(path.read_bytes()); raw[0] ^= 1; path.write_bytes(raw)
        self.refuse('SHA256')

    def test_missing_file(self):
        (self.root / 'one.bin').unlink()
        self.refuse('complete evidence file set')

    def test_extra_nested_file(self):
        (self.root / 'nested/unlisted.bin').write_bytes(b'extra')
        self.refuse('complete evidence file set')

    def test_duplicate_manifest_path(self):
        self.manifest['files'].append(dict(self.manifest['files'][0])); self.write()
        self.refuse('manifest path')

    def test_duplicate_json_key(self):
        path = self.root / 'manifest.json'
        path.write_text('{"schema_version":1,"schema_version":1,"files":[]}', encoding='utf-8')
        self.refuse('duplicate JSON key')

    def test_parent_traversal_cannot_authorize_external_file(self):
        outside = Path(self.temp.name) / 'outside.bin'; outside.write_bytes(b'outside')
        self.manifest['files'][0] = {'path': '../outside.bin', 'bytes': 7,
                                     'sha256': hashlib.sha256(b'outside').hexdigest()}
        self.write(); self.refuse('manifest path')
        self.assertEqual(outside.read_bytes(), b'outside')

    def test_noncanonical_or_self_paths(self):
        for name in ('nested//two.txt', './one.bin', '/one.bin', 'C:/one.bin',
                     'nested\\two.txt', 'manifest.json'):
            with self.subTest(name=name):
                self.manifest['files'][0]['path'] = name; self.write()
                self.refuse('manifest path')

    def test_wrong_counts_and_totals(self):
        for key in ('file_count', 'total_bytes'):
            with self.subTest(key=key):
                self.manifest[key] += 1; self.write(); self.refuse('inventory totals')
                self.manifest[key] -= 1

    def test_boolean_integer_fields_refused(self):
        for key in ('schema_version', 'file_count', 'total_bytes'):
            old = self.manifest[key]
            self.manifest[key] = True; self.write(); self.refuse('manifest schema')
            self.manifest[key] = old
        self.manifest['files'][0]['bytes'] = True; self.write()
        self.refuse('file byte bound')

    def test_actual_size_not_only_hash(self):
        self.manifest['files'][0]['bytes'] += 1; self.write()
        self.refuse('evidence length')

    def test_file_size_cap_before_large_allocation(self):
        self.manifest['files'][0]['bytes'] = 64 * 1024 * 1024 + 1; self.write()
        self.refuse('file byte bound')

    def test_real_reparse_file_when_os_allows(self):
        path = self.root / 'link.bin'
        try:
            path.symlink_to(self.root / 'one.bin')
        except (OSError, NotImplementedError) as error:
            self.skipTest('OS does not permit creating real symlinks: ' + type(error).__name__)
        self.refuse('reparse evidence')

    def test_manifest_symlink_rejected_before_content_read_when_os_allows(self):
        manifest = self.root / 'manifest.json'
        outside = Path(self.temp.name) / 'actual-manifest.json'
        manifest.replace(outside)
        try:
            manifest.symlink_to(outside)
        except (OSError, NotImplementedError) as error:
            self.skipTest('OS does not permit creating real symlinks: ' + type(error).__name__)
        self.refuse('reparse evidence')


if __name__ == '__main__':
    unittest.main()
