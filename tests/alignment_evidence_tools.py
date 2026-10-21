"""Permanent offline regression tests for full alignment evidence validation.

Usage: python tests/alignment_evidence_tools.py [--dataset DIR] [--workroot DIR]
The accepted input remains read-only. Every test clones bytes into its own tempdir.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

WORKSPACE = Path(__file__).resolve().parents[1]
DATASET = WORKSPACE / 'evidence/sprint18/alignment-fitness'
WORKROOT = None
VERIFIER = WORKSPACE / 'tools/oracle/verify-alignment-evidence.py'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class AlignmentEvidenceTools(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (DATASET / 'manifest.json').is_file():
            raise RuntimeError('accepted_dataset_missing: ' + str(DATASET))
        cls.original = {p.relative_to(DATASET).as_posix(): (len(p.read_bytes()), digest(p))
                        for p in DATASET.rglob('*') if p.is_file()}

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='alignment-tools-', dir=WORKROOT)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / 'evidence'
        shutil.copytree(DATASET, self.directory)

    def tearDown(self):
        actual = {p.relative_to(DATASET).as_posix(): (len(p.read_bytes()), digest(p))
                  for p in DATASET.rglob('*') if p.is_file()}
        self.assertEqual(actual, self.original, 'original accepted evidence changed')

    def invoke(self, success=False, expected_error=None):
        result = subprocess.run([sys.executable, str(VERIFIER), str(self.directory)],
                                capture_output=True, text=True, timeout=45, check=False)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)['status'],
                             'PASS_OFFLINE_FINITE_ALIGNMENT_ARTIFACT_VERIFICATION')
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            if expected_error:
                self.assertIn(expected_error, result.stderr)

    def modify(self, name, mutation):
        path = self.directory / name
        value = json.loads(path.read_text(encoding='utf-8-sig'))
        mutation(value)
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        manifest_path = self.directory / 'manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
        rows = [row for row in manifest['files'] if row['path'] == name]
        self.assertEqual(len(rows), 1)
        rows[0]['sha256'] = digest(path)
        rows[0]['bytes'] = path.stat().st_size
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n',
                                 encoding='utf-8')

    @staticmethod
    def first_nonempty_alignment(value):
        for row in value['actual_alpha_observations']:
            for group in row['evaluations']:
                for variant in group['measurement']['alignments']:
                    if variant['activities']:
                        return variant
        raise AssertionError('accepted evidence lacks complete nonempty alignment')

    def test_unmodified_accepted_evidence_passes(self):
        self.invoke(success=True)

    def test_raw_byte_corruption_fails_original_hash(self):
        with (self.directory / 'alignment-results.json').open('ab') as stream:
            stream.write(b' ')
        self.invoke(expected_error='full_original_file_hash')

    def test_rehashed_alignment_cost_is_recomputed(self):
        def mutate(value):
            variant = self.first_nonempty_alignment(value)
            variant['result']['Ok']['cost'] += 1
        self.modify('alignment-results.json', mutate)
        self.invoke(expected_error='alignment_cost_states')

    def test_rehashed_sync_index_is_replayed(self):
        def mutate(value):
            for row in value['actual_alpha_observations']:
                for group in row['evaluations']:
                    for variant in group['measurement']['alignments']:
                        for move in variant['result']['Ok']['moves']:
                            if 'SyncMove' in move:
                                move['SyncMove']['trace_event_index'] += 1
                                return
            raise AssertionError('accepted evidence lacks synchronous move')
        self.modify('alignment-results.json', mutate)
        self.invoke(expected_error='sync_label_index')

    def test_rehashed_frequency_cannot_replace_original_projection(self):
        def mutate(value):
            self.first_nonempty_alignment(value)['frequency'] += 1
        self.modify('alignment-results.json', mutate)
        self.invoke(expected_error='all_variants_and_frequencies')

    def test_rehashed_missing_manual_case_duplicate_other_is_refused(self):
        def mutate(value):
            rows = value['manual_reference_checks']['cases']
            first = next(row for row in rows if row['id'] == 'M01')
            index = next(i for i, row in enumerate(rows) if row['id'] == 'M02')
            rows[index] = copy.deepcopy(first)
        self.modify('alignment-results.json', mutate)
        self.invoke(expected_error='exact_unique_manual_cases')

    def test_rehashed_duplicate_native_label_is_refused(self):
        def mutate(value):
            rows = value['process_summaries']
            source = next(row for row in rows if row['label'] == 'mine')
            target = next(row for row in rows if row['label'] == 'align')
            target['label'] = source['label']
        self.modify('provenance.json', mutate)
        self.invoke(expected_error='unique_required_native_labels')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, default=DATASET)
    parser.add_argument('--workroot', type=Path)
    options, unittest_args = parser.parse_known_args()
    DATASET = options.dataset.absolute()
    WORKROOT = options.workroot.absolute() if options.workroot else None
    if WORKROOT is not None and not WORKROOT.is_dir():
        parser.error('--workroot must be an existing private directory')
    unittest.main(argv=[sys.argv[0], *unittest_args])
