"""Pure path-projection and dual-chain counterfactuals, no engine calls."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


PROJECT=module('public_projector',Path(__file__).with_name('project-public-evidence.py'))
AUDIT=module('public_benchmark_auditor',Path(__file__).parents[1]/'oracle/audit-miner-benchmark-evidence.py')


class PublicEvidenceProjection(unittest.TestCase):
    def test_number_lexemes_exact_including_wide_negative_zero(self):
        raw=b'{"counter":134371872001234567,"float":-0.000,"small":1e-19}'
        value=PROJECT.parse(raw);published=PROJECT.emit(value).encode()
        self.assertEqual(published,raw)
        self.assertEqual(PROJECT.numeric_tokens(value),AUDIT.numeric_lexeme_digest(raw))

    def test_only_declared_metadata_paths_aliased(self):
        absolute=str(PROJECT.ROOT/'private'/'classes')
        changes=[]
        value=PROJECT.project_strings({'origin_path':absolute,'jvm_arguments':['-Duser.home='+absolute]},changes=changes)
        self.assertEqual(value['origin_path'],'workspace:/private/classes')
        self.assertEqual(value['jvm_arguments'],['-Duser.home=workspace:/private/classes'])
        self.assertEqual(len(changes),2)
        with self.assertRaisesRegex(ValueError,'unknown_path_field'):
            PROJECT.project_strings({'unexpected_metadata':absolute})

    def test_scientific_and_exception_strings_never_scrubbed(self):
        path=str(PROJECT.ROOT/'private')
        for value in ({'input_xlog_before':{'attributes':[{'value':path}]}},{'exception':{'message':path}}):
            with self.assertRaisesRegex(ValueError,'path_in_scientific_string'):PROJECT.project_strings(value)
        scientific={'input_xlog_before':{'extensions':[{'uri':'http://www.xes-standard.org/concept.xesext'}]}}
        self.assertEqual(PROJECT.project_strings(scientific),scientific)
        self.assertIsNone(PROJECT.ABSOLUTE.search('workspace:/private/classes'))

    def test_descriptor_rebinding_does_not_rewrite_original_pins(self):
        old='1'*64;new='2'*64
        value={'summary':{'file':'summary.json','sha256':old,'bytes':PROJECT.Number('17')},'original_build_proof_sha256':old,'input_sha256':old}
        changes=[];PROJECT.descriptor_updates(value,{('summary.json',old,17):(new,19)},changes)
        self.assertEqual(value['summary']['sha256'],new)
        self.assertEqual(value['original_build_proof_sha256'],old)
        self.assertEqual(value['input_sha256'],old)
        self.assertEqual(changes[0]['kind'],'artifact_descriptor_rebound')

    def map(self,base,files):
        rows=[]
        for name,raw in files.items():
            path=base/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw)
            row={'path':name,'source_path':name,'original_sha256':PROJECT.sha(raw),'published_sha256':PROJECT.sha(raw),
                 'original_bytes':len(raw),'published_bytes':len(raw),'transformations':[],'preserved_original_capture':'.raw.' in name}
            if name.endswith('.json'):row['scientific_numeric_lexeme_sha256']=AUDIT.numeric_lexeme_digest(raw)
            rows.append(row)
        value={'schema_version':1,'status':'EXPLICIT_PATH_ONLY_PUBLIC_PROJECTION','manifest_excludes_itself':True,
               'original_class_runtime_jdk_pins_unchanged':True,'files':rows,'omissions':[]}
        path=base/'public-projection.json';path.write_text(json.dumps(value),encoding='utf-8');return path,value

    def test_projected_numeric_mutation_rehashed_file_still_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder);path,value=self.map(base,{'counter.json':b'{"counter":134371872001234567}'})
            changed=b'{"counter":134371872001234568}';(base/'counter.json').write_bytes(changed)
            value['files'][0]['published_sha256']=PROJECT.sha(changed)
            path.write_text(json.dumps(value),encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'projected_numeric_lexemes'):AUDIT.PublicProjection(path)

    def test_map_path_escape_and_scientific_pointer_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder);path,value=self.map(base,{'record.json':b'{"counter":1}'})
            value['files'][0]['source_path']='../outside'
            path.write_text(json.dumps(value),encoding='utf-8')
            with self.assertRaises(ValueError):AUDIT.PublicProjection(path)
            value['files'][0]['source_path']='record.json'
            value['files'][0]['transformations']=[{'kind':'path_alias','pointer':'/input_xlog_before/attributes/0/value'}]
            path.write_text(json.dumps(value),encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'scientific_projection_pointer'):AUDIT.PublicProjection(path)

    def test_only_two_root_publication_metadata_extras_allowed(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder);path,_=self.map(base,{'record.json':b'{"counter":1}'})
            (base/'README.md').write_text('Publication metadata, independently inventoried.',encoding='utf-8')
            (base/'manifest.json').write_text('{}',encoding='utf-8')
            AUDIT.PublicProjection(path)
            (base/'unexpected.txt').write_text('unlisted payload',encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'projection_complete_file_set'):AUDIT.PublicProjection(path)
            (base/'unexpected.txt').unlink()
            (base/'nested').mkdir();(base/'nested/README.md').write_text('not a root exception',encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'projection_complete_file_set'):AUDIT.PublicProjection(path)

    def test_raw_capture_bytes_remain_native_authority(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder)
            boot=b'S20_PROTOCOL {"phase":"BOOT_READY","pid":7,"nonce":"abcdef1234567890","process_id":"cold-r1-linear"}\r\n'
            terminal={'phase':'TERMINAL_READY','pid':7,'nonce':'abcdef1234567890','process_id':'cold-r1-linear',
                      'terminal_ready':{'file':'terminal-ready.json','sha256':'1'*64,'bytes':11},
                      'summary':{'file':'summary.json','sha256':'1'*64,'bytes':11},
                      'ledger':{'file':'iteration-ledger.jsonl','sha256':'1'*64,'bytes':11},'scheduled_calls':1,'completed_calls':1}
            raw=boot+b'original native console\r\nS20_PROTOCOL '+json.dumps(terminal,separators=(',',':')).encode()+b'\r\n'
            terminal['summary']['sha256']='2'*64;terminal['summary']['bytes']=12
            projected=boot+b'original native console\r\nS20_PROTOCOL '+json.dumps(terminal,separators=(',',':')).encode()+b'\r\n'
            record={'program_sha256':AUDIT.JAVA,'native_exit':0,'stdout_complete':True,'stderr_complete':True,
                    'output_limit':False,'capture_fault':False,'drain_timeout':False,
                    'stdout_bytes_persisted':len(raw),'stdout_sha256':PROJECT.sha(raw),
                    'stderr_bytes_persisted':0,'stderr_sha256':PROJECT.sha(b'')}
            files={'capture/benchmark.process.json':json.dumps(record).encode(),
                   'capture/benchmark.stdout':projected,'capture/benchmark.stderr':b'',
                   'capture/benchmark.raw.stdout':raw,'capture/benchmark.raw.stderr':b''}
            path,value=self.map(base,files)
            for row in value['files']:
                if row['path'].endswith('benchmark.stdout'):
                    row.update(original_sha256=PROJECT.sha(raw),original_bytes=len(raw))
                elif '.raw.' in row['path']:
                    row['source_path']=row['path'].replace('.raw.','.')
            path.write_text(json.dumps(value),encoding='utf-8');projection=AUDIT.PublicProjection(path)
            _,streams,_=AUDIT.native(base,'capture/benchmark.process.json',projection)
            self.assertEqual(streams['stdout'],projected)
            (base/'capture/benchmark.raw.stdout').write_bytes(raw+b'x')
            with self.assertRaisesRegex(ValueError,'stream_length'):AUDIT.native(base,'capture/benchmark.process.json',projection)

    def test_raw_protocol_identity_and_nonprotocol_bytes_cannot_be_rebound(self):
        boot=b'S20_PROTOCOL {"phase":"BOOT_READY","pid":7}\n'
        AUDIT.protocol_projection_binding(boot+b'actual console\n',boot+b'actual console\n')
        with self.assertRaisesRegex(ValueError,'boot_protocol_change'):
            AUDIT.protocol_projection_binding(boot,boot.replace(b'"pid":7',b'"pid":8'))
        with self.assertRaisesRegex(ValueError,'nonprotocol_console_change'):
            AUDIT.protocol_projection_binding(boot+b'actual console\n',boot+b'forged console\n')
        terminal={'phase':'TERMINAL_READY','pid':7,'nonce':'abcdef1234567890','process_id':'cold-r1-linear',
                  'terminal_ready':{'file':'terminal-ready.json','sha256':'1'*64,'bytes':11},
                  'summary':{'file':'summary.json','sha256':'1'*64,'bytes':11},
                  'ledger':{'file':'iteration-ledger.jsonl','sha256':'1'*64,'bytes':11}}
        line=b'S20_PROTOCOL '+json.dumps(terminal,separators=(',',':')).encode()+b'\n'
        with self.assertRaisesRegex(ValueError,'identity_or_value_change'):
            AUDIT.protocol_projection_binding(line,line.replace(b'"pid":7',b'"pid":8'))

    def test_ntfs_junction_attribute_rejected_before_read(self):
        with patch.object(Path,'lstat',return_value=SimpleNamespace(st_file_attributes=1024)):
            with self.assertRaisesRegex(ValueError,'reparse_path'):PROJECT.no_reparse(Path('junction'))

    def test_duplicate_key_and_invalid_scientific_json_stay_byte_exact(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder);source=base/'source';source.mkdir()
            scientific={'conversions/inputs/duplicate.json':b'{"key":1,"key":2}',
                        'conversion-boundaries/inputs/broken.json':b'\xffnot JSON',
                        'conversions/cases/P01/inverse/payload.json':b'{"unfinished":'}
            for name,raw in scientific.items():
                path=source/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw)
            miner=source/'miner-performance';miner.mkdir()
            for name in ('environment.json','hardware.json'):(miner/name).write_bytes(b'{}')
            index={'environment_path':'environment.json','environment_sha256':PROJECT.sha(b'{}'),
                   'hardware_path':'hardware.json','hardware_sha256':PROJECT.sha(b'{}')}
            (miner/'index.json').write_text(json.dumps(index),encoding='utf-8')
            output=base/'published';manifest=PROJECT.generate(source,output)
            rows={r['path']:r for r in manifest['files']}
            for name,raw in scientific.items():
                self.assertEqual((output/name).read_bytes(),raw)
                self.assertEqual(rows[name]['representation'],'opaque_scientific_bytes')
                self.assertEqual(rows[name]['transformations'],[])
                self.assertEqual(rows[name]['original_sha256'],rows[name]['published_sha256'])
            AUDIT.PublicProjection(output/'public-projection.json')
            # Reclassifying metadata as opaque must not bypass strict parsing.
            row=rows['miner-performance/hardware.json'];row['representation']='opaque_scientific_bytes'
            (output/'public-projection.json').write_text(PROJECT.emit(manifest),encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'opaque_representation_path_not_scientific'):
                AUDIT.PublicProjection(output/'public-projection.json')
            (miner/'hardware.json').write_bytes(b'{"key":1,"key":2}')
            with self.assertRaisesRegex(ValueError,'duplicate_json_key'):PROJECT.generate(source,base/'must-not-publish')
            self.assertFalse((base/'must-not-publish').exists())


if __name__=='__main__':unittest.main()
