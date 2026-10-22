"""Pure temporary-file tests for the explicit S21 public projection policy."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / 'tools/sprint21/project-public-evidence.py'
spec = importlib.util.spec_from_file_location('s21_public_projector', MODULE)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s21-projection-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.workspace = self.base / 'workspace'
        self.profile = self.base / 'profile'
        self.workspace.mkdir()
        self.profile.mkdir()
        self.output = self.workspace / 'public'
        self.manifest = self.workspace / 'allowlist.json'

    def entry(self, source, raw, mode='bytes', public='proof/file.json', **kwargs):
        destination = self.workspace.joinpath(*source.split('/'))
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
        return dict(source=source, sha256=p.sha(raw), public_path=public, mode=mode, **kwargs)

    def project(self, entries):
        self.manifest.write_text(json.dumps({'schema_version': 1, 'entries': entries}), encoding='utf-8')
        return p.project(self.workspace, self.manifest, self.output, self.profile)

    def test_explicit_paths_preserve_order_numeric_lexemes_and_scientific_strings(self):
        document = ('{"path":' + json.dumps(str(self.workspace / 'tools' / 'proof.py'))
                    + ',"n":9007199254740993,"max":18446744073709551615,"f":1.2300e+004,"z":-0,'
                    + '"science":{"label":"approve [A-Z] — π","decimal_text":"1.2300e+004","uuid":"12345678-1234-1234-1234-123456789abc"},'
                    + '"home":' + json.dumps(str(self.profile / 'cache')) + '}').encode('utf-8')
        entry = self.entry('proof.json', document, mode='json_paths', json_pointers=['/path', '/home'])
        original = p.parse(document)
        manifest = self.project([entry])
        projected_raw = (self.output / 'proof/file.json').read_bytes()
        projected = p.parse(projected_raw)
        self.assertEqual(list(original), list(projected))
        self.assertEqual(projected['path'], 'workspace:/tools/proof.py')
        self.assertEqual(projected['home'], 'userprofile:/cache')
        for key in ('n', 'max', 'f', 'z', 'science'):
            self.assertEqual(original[key], projected[key])
        for token in (b'9007199254740993', b'18446744073709551615', b'1.2300e+004', b'"z":-0'):
            self.assertIn(token, projected_raw)
        item = manifest['entries'][0]
        self.assertEqual(item['numeric_tokens_sha256_before'], item['numeric_tokens_sha256_after'])
        self.assertEqual(item['original_sha256'], p.sha(document))
        self.assertEqual(item['public_sha256'], p.sha(projected_raw))
        self.assertEqual((self.workspace / 'proof.json').read_bytes(), document)

    def test_unknown_and_unapproved_paths_fail_before_output_creation(self):
        for raw, pointers in [(b'{"p":"Z:/unknown/user/file"}', ['/p']),
                              (json.dumps({'p': str(self.workspace / 'private')}).encode(), [])]:
            with self.subTest(raw=raw):
                entry = self.entry('path.json', raw, mode='json_paths', json_pointers=pointers)
                with self.assertRaisesRegex(ValueError, 'absolute_path'):
                    self.project([entry])
                self.assertFalse(self.output.exists())

    def test_pointer_must_be_exact_existing_string_and_properly_escaped(self):
        raw = json.dumps({'a/b': {'~path': str(self.workspace / 'safe')}}).encode()
        entry = self.entry('p.json', raw, mode='json_paths', json_pointers=['/a~1b/~0path'])
        self.project([entry])
        self.assertEqual(p.parse((self.output / 'proof/file.json').read_bytes())['a/b']['~path'], 'workspace:/safe')

    def test_missing_or_nonstring_pointers_and_prefix_boundary_reject(self):
        cases = [(b'{"value":9007199254740993}', ['/value'], 'pointer_not_string'),
                 (b'{"value":"plain scientific label"}', ['/missing'], 'unused_json_pointer'),
                 (json.dumps({'value': str(self.workspace) + '-other/file'}).encode(), ['/value'], 'path_prefix_boundary')]
        for raw, pointers, reason in cases:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(ValueError, reason):
                    self.project([self.entry('p.json', raw, mode='json_paths', json_pointers=pointers)])
                self.assertFalse(self.output.exists())

    def test_secret_material_and_credential_filenames_cannot_be_copied(self):
        cases = [('safe.json', b'{"password":"value"}'), ('safe.json', b'{"sessions":{}}'),
                 ('safe.json', b'{"auth":{"users":[]}}'), ('private-credentials.json', b'{}'),
                 ('postgres-private/data.json', b'{}'), ('proof.log', b'postgresql://owner:secret@localhost/db'),
                 ('proof.log', b'pi_session=private-cookie')]
        for source, raw in cases:
            with self.subTest(source=source, raw=raw):
                with self.assertRaisesRegex(ValueError, 'sensitive_'):
                    self.project([self.entry(source, raw)])
                self.assertFalse(self.output.exists())

    def test_omission_inventories_only_identity_size_and_reason(self):
        raw = b'{"auth":{"password":"PRIVATE-DO-NOT-PUBLISH"}}'
        entry = self.entry('private-credentials.json', raw, mode='omit', public='omitted/private-credentials.json', reason='Credential material omitted')
        manifest = self.project([entry])
        item = manifest['entries'][0]
        self.assertEqual(item['original_sha256'], p.sha(raw))
        self.assertEqual(item['original_bytes'], len(raw))
        self.assertIsNone(item['public_sha256'])
        self.assertFalse((self.output / 'omitted').exists())
        self.assertNotIn(b'PRIVATE-DO-NOT-PUBLISH', (self.output / 'projection-manifest.json').read_bytes())

    def test_duplicate_json_keys_and_nonfinite_values_are_rejected(self):
        for raw in (b'{"a":1,"a":2}', b'{"n":NaN}'):
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(ValueError, 'duplicate_json_key|nonfinite_json'):
                    self.project([self.entry('bad.json', raw, mode='json_paths')])

    def test_frozen_scientific_bytes_are_exact_and_opaque_cannot_hide_metadata(self):
        raw = b'{"activity":"C:/scientific-example/label","n":18446744073709551615}'
        entry = self.entry('fixtures/inputs/manual.json', raw, public='conversion/inputs/manual.json', opaque_scientific=True)
        self.project([entry])
        self.assertEqual((self.output / 'conversion/inputs/manual.json').read_bytes(), raw)
        self.output = self.workspace / 'other-output'
        with self.assertRaisesRegex(ValueError, 'opaque_scientific_location'):
            self.project([self.entry('metadata.json', b'{}', opaque_scientific=True)])

    def test_only_exact_pinned_corpus_negative_json_remains_byte_identical(self):
        fixtures = MODULE.parents[2] / 'fixtures/conversions'
        destination = self.workspace / 'fixtures/conversions'
        destination.mkdir(parents=True)
        (destination / 'corpus.json').write_bytes((fixtures / 'corpus.json').read_bytes())
        raw = (fixtures / 'duplicate-key.json').read_bytes()
        source = '.local/sprint21/root/conversion-run02/inputs/duplicate-key.json'
        public = 'conversions/inputs/duplicate-key.json'
        self.project([self.entry(source, raw, public=public, opaque_scientific=True)])
        self.assertEqual((self.output / public).read_bytes(), raw)
        self.output = self.workspace / 'unknown-negative'
        for unknown in (b'{"intentionally incomplete":', raw + b' ',
                        ('{"hidden":"' + ''.join('\\u%04x' % ord(c) for c in str(self.profile / 'private'))).encode()):
            with self.subTest(unknown=unknown):
                with self.assertRaisesRegex(ValueError, 'unapproved_malformed_scientific_input'):
                    self.project([self.entry(source, unknown, public=public, opaque_scientific=True)])
                self.assertFalse(self.output.exists())

    def test_machine_paths_in_nonopaque_text_and_hash_mismatch_reject(self):
        raw = ('actual machine: ' + str(self.profile / 'cache')).encode()
        with self.assertRaisesRegex(ValueError, 'machine_path_leak'):
            self.project([self.entry('capture.log', raw, public='capture.log')])
        entry = self.entry('hash.json', b'{}')
        entry['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'source_hash_mismatch'):
            self.project([entry])

    def test_fresh_output_containment_and_casefold_duplicates(self):
        entry = self.entry('source.json', b'{}')
        self.output.mkdir()
        marker = self.output / 'keep'
        marker.write_bytes(b'unchanged')
        with self.assertRaisesRegex(ValueError, 'fresh_output_required'):
            self.project([entry])
        self.assertEqual(marker.read_bytes(), b'unchanged')
        self.output = self.workspace / 'new'
        entry['public_path'] = '../escape.json'
        with self.assertRaisesRegex(ValueError, 'relative_path_required'):
            self.project([entry])
        entry['public_path'] = 'proof/file.json'
        duplicate = self.entry('other.json', b'{}', public='PROOF/FILE.JSON')
        with self.assertRaisesRegex(ValueError, 'duplicate_entry'):
            self.project([entry, duplicate])
        self.assertFalse(self.output.exists())

    def test_reparse_source_is_rejected(self):
        source = self.workspace / 'source.json'
        source.write_bytes(b'{}')
        link = self.workspace / 'link.json'
        try:
            link.symlink_to(source)
        except OSError as error:
            if isinstance(error, PermissionError) or getattr(error, 'winerror', None) == 1314:
                self.skipTest('Creating a test symlink requires unavailable Windows privilege')
            raise
        entry = dict(source='link.json', sha256=p.sha(b'{}'), public_path='proof.json', mode='bytes')
        with self.assertRaisesRegex(ValueError, 'reparse_path'):
            self.project([entry])

    def test_postread_source_change_is_detected_before_publication(self):
        entry = self.entry('source.json', b'{"n":9007199254740993}')
        original = p.bounded
        reads = 0
        def changing(path, limit=p.MAX_FILE, boundary=None):
            nonlocal reads
            if Path(path).name == 'source.json':
                reads += 1
                if reads == 2:
                    Path(path).write_bytes(b'{"n":9007199254740994}')
            return original(path, limit, boundary)
        with mock.patch.object(p, 'bounded', changing):
            with self.assertRaisesRegex(ValueError, 'source_changed'):
                self.project([entry])
        self.assertFalse(self.output.exists())

    def test_uri_requires_exact_pointer_and_bytes_mode_preserves_original(self):
        raw = b'{ "route" : "/conversions/jobs/job-7/events", "revision":18446744073709551615 }\n'
        entry = self.entry('http.json', raw, uri_pointers=['/route'])
        manifest = self.project([entry])
        self.assertEqual((self.output / 'proof/file.json').read_bytes(), raw)
        self.assertEqual(manifest['entries'][0]['uri_pointers'], ['/route'])
        self.output = self.workspace / 'other-output'
        raw = b'{"route":"/conversions","not_route":"/conversions"}'
        with self.assertRaisesRegex(ValueError, 'unapproved_absolute_path'):
            self.project([self.entry('http2.json', raw, uri_pointers=['/route'])])

    def test_explicit_uri_type_does_not_authorize_traversal_drives_or_profile(self):
        values = ['//host/path', '/conversions/../backup', '/conversions/%2e%2e/backup',
                  'Z:/private', str(self.profile / 'cache'), '/unknown/private/path',
                  '/conversions/jobs/job-7/events?private=value', '/conversions\\jobs',
                  '/conversions/' + str(self.workspace), 'https://example.org/health']
        for value in values:
            with self.subTest(value=value):
                raw = json.dumps({'route': value}).encode()
                with self.assertRaises(ValueError):
                    self.project([self.entry('bad-uri.json', raw, mode='json_paths', uri_pointers=['/route'])])
                self.assertFalse(self.output.exists())

    def test_json_path_projection_never_rebinds_native_capture_hashes(self):
        original_stream_hash = p.sha(b'original native stream')
        raw = json.dumps({'program': str(self.workspace / 'native.exe'),
                          'stdout_sha256': original_stream_hash,
                          'route': '/health', 'stdout_bytes': 123}).encode()
        self.project([self.entry('capture.json', raw, mode='json_paths',
                                 json_pointers=['/program'], uri_pointers=['/route'])])
        public = p.parse((self.output / 'proof/file.json').read_bytes())
        self.assertEqual(public['stdout_sha256'], original_stream_hash)
        self.assertEqual(public['stdout_bytes'], p.Number('123'))
        self.assertEqual(public['route'], '/health')

    def scientific_report(self):
        return dict(schema_version=1,
                    method_sha256='49dc32d1f4219965ea57cc79caa9355974269fab989cc38d09173c8e734e619b',
                    status='converted', reason='lossless_core', **{'from': 'xes', 'to': 'csv'},
                    input_sha256='a' * 64, input_bytes=430, allow_metadata_loss=False,
                    target_sha256='b' * 64, target_bytes=125, payload_file='payload.csv',
                    evidence={'xpath': '/log/trace[0]/event[0]',
                              'mapping': {'/pnml/net/page': 'unchanged'},
                              'max_revision': 18446744073709551615})

    def test_narrow_typed_scientific_report_preserves_xpath_keys_and_every_byte(self):
        raw = json.dumps(self.scientific_report(), ensure_ascii=False, indent=2).encode()
        entry = self.entry('http/007.body', raw, public='conversions/reports/job-7/report.json', opaque_scientific=True)
        manifest = self.project([entry])
        self.assertEqual((self.output / entry['public_path']).read_bytes(), raw)
        item = manifest['entries'][0]
        self.assertEqual(item['original_sha256'], item['public_sha256'])
        self.assertEqual(item['numeric_tokens_sha256_before'], item['numeric_tokens_sha256_after'])

    def test_opaque_never_authorizes_actual_machine_prefix_even_json_unicode_escaped(self):
        cases = [json.dumps({'label': str(self.workspace / 'private')}).encode(),
                 ('{"label":"' + ''.join('\\u%04x' % ord(c) for c in str(self.profile / 'private')) + '"}').encode()]
        for raw in cases:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(ValueError, 'machine_path_leak'):
                    self.project([self.entry('fixtures/inputs/leak.json', raw,
                                             public='conversions/inputs/leak.json', opaque_scientific=True)])
                self.assertFalse(self.output.exists())
        report = self.scientific_report()
        report['evidence']['label'] = str(self.profile / 'private')
        with self.assertRaisesRegex(ValueError, 'machine_path_leak'):
            self.project([self.entry('http/008.body', json.dumps(report).encode(),
                                     public='conversions/reports/job-8/report.json', opaque_scientific=True)])

    def test_report_location_cannot_hide_metadata_or_credentials(self):
        for document in ({'route': '/conversions', 'status': 'passed'},
                         {**self.scientific_report(), 'password': 'secret-value'}):
            with self.subTest(document=document):
                with self.assertRaisesRegex(ValueError, 'scientific_report_schema|sensitive_'):
                    self.project([self.entry('http/009.body', json.dumps(document).encode(),
                                             public='conversions/reports/job-9/report.json', opaque_scientific=True)])
                self.assertFalse(self.output.exists())

    def test_trusted_workspace_does_not_probe_external_cloud_ancestors_or_profile(self):
        entry = self.entry('proof.json', b'{"n":18446744073709551615}')
        original = p.no_reparse
        checked = []
        def cloud_boundary(path):
            path = Path(path)
            checked.append(path)
            if path in self.workspace.parents or path == self.profile:
                raise ValueError('external_cloud_ancestor_must_not_be_probed')
            return original(path)
        with mock.patch.object(p, 'no_reparse', cloud_boundary):
            self.project([entry])
        self.assertIn(self.workspace, checked)
        self.assertNotIn(self.profile, checked)
        self.assertEqual((self.output / 'proof/file.json').read_bytes(), b'{"n":18446744073709551615}')

    def test_output_outside_exact_workspace_is_refused(self):
        entry = self.entry('proof.json', b'{}')
        self.output = self.base / 'outside-public'
        with self.assertRaisesRegex(ValueError, 'output_outside_workspace'):
            self.project([entry])
        self.assertFalse(self.output.exists())

    def test_reparse_output_parent_inside_workspace_is_refused(self):
        entry = self.entry('proof.json', b'{}')
        outside = self.base / 'outside'
        outside.mkdir()
        link = self.workspace / 'write-link'
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError as error:
            if isinstance(error, PermissionError) or getattr(error, 'winerror', None) == 1314:
                self.skipTest('Creating a test symlink requires unavailable Windows privilege')
            raise
        self.output = link / 'public'
        with self.assertRaisesRegex(ValueError, 'reparse_path'):
            self.project([entry])
        self.assertFalse((outside / 'public').exists())

    def test_calibrated_windows_ctime_representation_only_cross_family(self):
        # Values from the actual unchanged-file Windows 3.13 calibration.
        values = dict(st_dev=6798442591175793011, st_ino=844424933275387,
                      st_mode=33206, st_size=21935, st_mtime_ns=1792698498227143800,
                      st_ctime_ns=1792697471908509800, st_birthtime_ns=1792697471908509800,
                      st_file_attributes=32)
        path_before = SimpleNamespace(**values)
        path_after = SimpleNamespace(**values)
        handle_values = {**values, 'st_ctime_ns': values['st_mtime_ns']}
        handle_before = SimpleNamespace(**handle_values)
        handle_after = SimpleNamespace(**handle_values)
        self.assertTrue(p.stable_read_identity(path_before, handle_before, handle_after, path_after, platform='nt'))
        # No cross-family exception is granted on other platforms.
        self.assertFalse(p.stable_read_identity(path_before, handle_before, handle_after, path_after, platform='posix'))
        for family in ('path', 'handle'):
            with self.subTest(family=family):
                a, b, c, d = path_before, handle_before, handle_after, path_after
                if family == 'path':
                    d = SimpleNamespace(**{**values, 'st_ctime_ns': values['st_ctime_ns'] + 1})
                else:
                    c = SimpleNamespace(**{**handle_values, 'st_ctime_ns': handle_values['st_ctime_ns'] + 1})
                self.assertFalse(p.stable_read_identity(a, b, c, d, platform='nt'))
        for field in ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_birthtime_ns', 'st_file_attributes'):
            with self.subTest(cross_family_field=field):
                changed = {**handle_values, field: handle_values[field] + 1}
                # Even a stable different handle must not be accepted for this path.
                self.assertFalse(p.stable_read_identity(path_before, SimpleNamespace(**changed), SimpleNamespace(**changed), path_after, platform='nt'))

    def test_exact_browser_download_and_boundary_report_names_remain_byte_identical(self):
        raw = json.dumps(self.scientific_report(), indent=2).encode()
        entries = [self.entry('browser-private/xes-csv.report.json', raw,
                              public='browser/xes-csv.report.json', opaque_scientific=True),
                   self.entry('boundary-private/cases/novel-csv/report.json', raw,
                              public='conversion-boundaries/cases/novel-csv/report.json', opaque_scientific=True)]
        self.project(entries)
        for entry in entries:
            self.assertEqual((self.output / entry['public_path']).read_bytes(), raw)
        self.output = self.workspace / 'other-public'
        with self.assertRaisesRegex(ValueError, 'opaque_scientific_location'):
            self.project([self.entry('browser-private/metadata.json', b'{}',
                                     public='browser/metadata.json', opaque_scientific=True)])

    def test_absolute_detector_distinguishes_explicit_aliases_from_real_file_uris(self):
        for alias in ('workspace:/tools/proof.py', 'userprofile:/cache'):
            with self.subTest(alias=alias):
                self.assertIsNone(p.ABSOLUTE.search(alias))
        for absolute in ('file:/C:/private', 'file:///home/private', 'see file:/private',
                         'C:/private', 'C:\\private', '\\\\server\\share\\private'):
            with self.subTest(absolute=absolute):
                self.assertIsNotNone(p.ABSOLUTE.search(absolute))

if __name__ == '__main__':
    unittest.main()
