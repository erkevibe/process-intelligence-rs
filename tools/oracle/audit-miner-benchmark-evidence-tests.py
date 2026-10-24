"""Pure counterfactual checks; no miner, compiler, metric engine or OS probing."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import json

SPEC=importlib.util.spec_from_file_location('benchmark_evidence',Path(__file__).with_name('audit-miner-benchmark-evidence.py'))
AUDIT=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class BenchmarkEvidence(unittest.TestCase):
    def summary(self):
        return {'jvm_arguments':['-Xmx512m','-XX:ActiveProcessorCount=2','-XX:-UsePerfData','-da',
                '-Dfile.encoding=UTF-8','-Duser.timezone=UTC','-Djava.awt.headless=true'],
                'available_processors':2,'assertions_enabled':False}

    def test_exact_filetime_large_integer_and_last_100ns(self):
        value=134371872001234567
        self.assertGreater(value,2**53)
        text=AUDIT.filetime_iso(value)
        self.assertTrue(text.endswith('.1234567Z'),text)
        self.assertTrue(AUDIT.filetime_iso(value+1).endswith('.1234568Z'))
        self.assertEqual(AUDIT.filetime_iso(10000000),'1601-01-01T00:00:01.0000000Z')
        for bad in (True,1.0,-1):
            with self.assertRaises(ValueError):AUDIT.filetime_iso(bad)

    def test_median_large_nanos_is_exact_rational(self):
        a=2**60+1;b=a+1
        value=AUDIT.stats([{'call_id':'a','engine_time_nanos':a},{'call_id':'b','engine_time_nanos':b}])
        self.assertEqual(value['median_nanos_exact'],{'numerator':a+b,'denominator':2})
        self.assertEqual(value['raw_engine_nanos'],[a,b])
        self.assertIsNone(AUDIT.stats([])['median_nanos_exact'])

    def test_fresh_jvm_requires_pid_creation_pair(self):
        seen=set();row={'pid':19,'native_creation_utc':'2026-10-22T09:00:00.0000001Z'}
        AUDIT.fresh_identity(seen,row)
        with self.assertRaisesRegex(ValueError,'identity_reused'):AUDIT.fresh_identity(seen,row)
        AUDIT.fresh_identity(seen,{**row,'native_creation_utc':'2026-10-22T09:00:00.0000002Z'})
        self.assertEqual(len(seen),2)

    def test_jvm_flags_required_and_conflicts_rejected(self):
        self.assertFalse(AUDIT.jvm_flags(self.summary())['heap_cap_is_memory_measurement'])
        for flag in self.summary()['jvm_arguments']:
            value=self.summary();value['jvm_arguments'].remove(flag)
            with self.subTest(missing=flag),self.assertRaises(ValueError):AUDIT.jvm_flags(value)
        for flag in ['-Xmx2g','-ea','-XX:+UsePerfData','-Duser.timezone=Europe/London']:
            value=self.summary();value['jvm_arguments'].append(flag)
            with self.subTest(conflict=flag),self.assertRaises(ValueError):AUDIT.jvm_flags(value)
        value=self.summary();value['available_processors']=8
        with self.assertRaises(ValueError):AUDIT.jvm_flags(value)

    def test_hardware_hash_tamper_and_unavailable_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder);path=base/'hardware.json'
            original={'status':'unavailable','observation_utc':'2026-10-22T09:00:00Z','reason':'CIM timed out'}
            raw=json.dumps(original).encode('utf-8');path.write_bytes(raw)
            index={'hardware_path':'hardware.json','hardware_sha256':AUDIT.digest(raw)}
            result=AUDIT.hardware(base,index)
            self.assertEqual(result['metadata'],original)
            self.assertTrue(result['unavailable_not_imputed'])
            path.write_bytes(raw+b' ')
            with self.assertRaisesRegex(ValueError,'hardware_sha256'):AUDIT.hardware(base,index)

    def test_predeclared_class_pins_not_summary_self_attestation(self):
        expected={key:{'class':name,'sha256':'1'*64} for key,name in AUDIT.CLASS_NAMES.items()}
        summary={key:dict(row) for key,row in expected.items()}
        AUDIT.observed_classes(summary,expected)
        summary['parser_identity']['sha256']='2'*64
        with self.assertRaisesRegex(ValueError,'observed_class_binding'):AUDIT.observed_classes(summary,expected)
        with self.assertRaisesRegex(ValueError,'missing_predeclared_class_identity'):AUDIT.observed_classes(summary,{})

    def test_environment_descriptor_requires_exact_index_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder);raw=b'{"schema_version":1}'
            (base/'environment.json').write_bytes(raw)
            index={'environment_path':'environment.json','environment_sha256':'0'*64}
            with self.assertRaisesRegex(ValueError,'environment_sha256'):AUDIT.environment(base,index)


if __name__=='__main__':
    unittest.main()
