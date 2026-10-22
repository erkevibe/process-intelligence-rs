"""Pure, fail-closed audit of the frozen SplitMiner benchmark; no engine runs.

All 64 scheduled calls remain rows, including warmups, failures and unexecuted
calls. Memory is native process lifetime-through-terminal high-water, not heap
or per-call memory. Historical quality is a conditional carry, never a new score.
"""
import argparse
from collections import Counter, defaultdict
import contextlib
from datetime import datetime, timezone, timedelta
from decimal import Decimal
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
CORPUS = '9cb9a9ff15e07f07c88545147f439ddb09da57a37ee75e02b3b5f070e250ba78'
QUALITY_MANIFEST = '2cb5f59604ec5fff5a9eee2b7f22861bfb713e3bd144d219ecdd315f3bc94626'
JAVA = '9fcc7d5d43918e389df240d44601c98a4d3aa9e7d0cbbd6d208304e0b574c7e2'
JAVAC = '9a54effe7088d627a433a61da65d71fb420b5a67d163577c6c4f0ec3dfc3dbd6'
CLASSPATH = 'b44143812c83af2c12299655914a0463ef8dbaf1a700ac1f72426e668c1ee4c5'
MINER_PROOF = '8649b4d4f2a465954c2f999aa613fd04ff24aa818bb96ddf8390553d8e742d00'
SEMANTIC_SOURCE = '17479acca0cd6587b91002b8c58e7279c70c702e571189402b195b7d1cdf1878'
ADMITTED = {'linear','exclusive-choice','parallel-interleavings','short-loop','rare-noise','empty-trace'}
CLASS_NAMES = {
    'algorithm_identity':'org.apromore.splitminer.SplitMiner',
    'parser_identity':'org.deckfour.xes.in.XesXmlParser',
    'exporter_identity':'org.apromore.processmining.plugins.bpmn.plugins.BpmnExportPlugin',
    'harness_identity':'SplitMinerBenchmarkHarness',
    'xes_observer_identity':'SplitMinerBenchmarkXesObserver'}
# Actual pre-publication bytecode, independently extracted/compiled and audited.
# A projected descriptor/map cannot self-authorize a replacement executable.
ACTUAL_CLASS_PINS = {
    'algorithm_identity':'e8535a6b65b7e758a49e757d635e8797071b8e860bc8d1c6859e592eb1ee21ad',
    'parser_identity':'b010d5927ef60f61ef8181064a4ade78f6b29238bb98e1fd9fd9aa397ec64188',
    'exporter_identity':'5d29a33c4e67be64f15acdd06b5fc010ea1307aaefb288ded5f76a9a6976a826',
    'harness_identity':'0a3df0a9f57d34f8a1a5b4c83923579f0ad3c53fb66b60748303b1ffb57e39b8',
    'xes_observer_identity':'e0e886894f992753ddc98f0ebed34a1cedb5c65a2d359a45ec90033bd8402d1e'}
QUALITY_SOURCES = {
    'audit-quality-cohort.py':'db642a1159380fb7560e1337148e2b7aff1612d4384fbe3e23b59ec041652b08',
    'audit-quality-evidence.py':'8c60582d3e64c1ca2197fd1ebf9189d8ce96d568b93e9cd6d34c9395fcba47a6',
    'validate-quality-net-graph.py':'9b820eb611598a421ac6654341ed626d4db3b6ef2fbc5f20c27b5cbafa63fc28',
    'compare-quality-graphs.py':'159b6f052aa413903093e3a2faf3bf0f9ae56c42894310986681cfe69b487c5c'}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def integer(value, reason, minimum=0):
    require(type(value) is int and value >= minimum, reason)
    return value


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def read(path, cap=32*1024*1024):
    require(path.is_file() and not path.is_symlink(), 'regular_file_required')
    require(path.stat().st_size <= cap, 'file_cap')
    raw = path.read_bytes()
    require(len(raw) <= cap, 'file_grew')
    return raw


def pairs(rows):
    out = {}
    for key, value in rows:
        require(key not in out, 'duplicate_json_key')
        out[key] = value
    return out


def parse(raw):
    return json.loads(raw.decode('utf-8', errors='strict'), object_pairs_hook=pairs,
                      parse_float=Decimal, parse_constant=lambda x: (_ for _ in ()).throw(ValueError('nonfinite_json')))


def load(path, cap=32*1024*1024):
    return parse(read(path, cap))


class PublicProjection:
    """Explicit dual identity: preserved native bytes vs projected metadata.

    The manifest is external provenance, not permission to change science.
    Independent original-to-public comparison remains a required publication
    gate; this replay verifies every included published file and raw capture.
    """
    def __init__(self,path):
        self.base=path.parent
        self.manifest_sha256=digest(read(path))
        manifest=load(path)
        require(manifest['schema_version']==1 and manifest['status']=='EXPLICIT_PATH_ONLY_PUBLIC_PROJECTION','public_projection_status')
        require(manifest['manifest_excludes_itself'] is True and manifest['original_class_runtime_jdk_pins_unchanged'] is True,'public_projection_scope')
        self.rows={}
        for row in manifest['files']:
            name=row['path'];require(name not in self.rows,'duplicate_projection_path')
            raw=read(child(self.base,name))
            require(len(raw)==row['published_bytes'] and digest(raw)==row['published_sha256'].lower(),'projected_file_identity')
            require(re.fullmatch('[0-9a-fA-F]{64}',row['original_sha256']),'projection_original_sha256')
            integer(row['original_bytes'],'projection_original_bytes')
            for change in row['transformations']:
                require(change['kind'] in ('path_alias','artifact_descriptor_rebound','index_metadata_descriptor_rebound','projected_protocol_not_raw_capture'),'undeclared_projection_change_kind')
                pointer=change['pointer'];parts=pointer.split('/')
                require(not any(p in ('input_xlog_before','input_xlog_after','graph','exception','events','attributes','traces') for p in parts),'scientific_projection_pointer')
                if change['kind']=='path_alias':
                    require(parts[-1] in ('program','classes','origin_path','code_source') or
                            parts[-1]=='path' and 'java_sources' in parts or
                            parts[-1]=='file' and 'native_counter_calibrations' in parts or
                            'jvm_arguments' in parts,'unknown_path_projection_pointer')
                elif change['kind']=='projected_protocol_not_raw_capture':
                    require(name.endswith('/capture/benchmark.stdout') and pointer=='protocol-only','unexpected_protocol_projection')
                elif change['kind']=='index_metadata_descriptor_rebound':
                    require(name=='miner-performance/index.json' and pointer in ('/environment_sha256','/hardware_sha256'),'unexpected_metadata_rebinding')
            child(self.base,row['source_path'])
            require(row.get('representation') in (None,'opaque_scientific_bytes'),'unknown_projection_representation')
            if row.get('representation')=='opaque_scientific_bytes':
                require(opaque_scientific_path(name),'opaque_representation_path_not_scientific')
                require(not row['transformations'] and row['original_sha256'].lower()==row['published_sha256'].lower() and row['original_bytes']==row['published_bytes'],'opaque_scientific_bytes_changed')
            elif name.endswith('.json'):
                parse(raw)  # All metadata keeps strict duplicate-key rejection.
                require(numeric_lexeme_digest(raw)==row['scientific_numeric_lexeme_sha256'],'projected_numeric_lexemes')
            self.rows[name]=row
        actual={p.relative_to(self.base).as_posix() for p in self.base.rglob('*') if p.is_file()}
        required=set(self.rows)|{path.relative_to(self.base).as_posix()}
        # Root publication inventory and prose are independently verified by
        # the full manifest auditor. Excluding them here prevents a map/manifest
        # self-hash cycle; no other unlisted payload is admitted.
        require(required<=actual and actual-required<= {'manifest.json','README.md'},'projection_complete_file_set')

    def entry(self,path):
        require(path.resolve().is_relative_to(self.base.resolve()),'projection_file_scope')
        name=path.resolve().relative_to(self.base.resolve()).as_posix()
        require(name in self.rows,'unlisted_projected_file')
        return self.rows[name]

    def original_sha(self,path):
        return self.entry(path)['original_sha256'].lower()


def opaque_scientific_path(name):
    parts=PurePosixPath(name).parts
    if len(parts)>=3 and parts[0] in ('conversions','conversion-boundaries') and parts[1]=='inputs':return True
    return re.fullmatch(r'conversions/cases/[^/]+/(forward|inverse)/payload\.json|conversion-boundaries/cases/[^/]+/payload\.json',name) is not None


def numeric_lexeme_digest(raw):
    class Token(str):pass
    value=json.loads(raw.decode('utf-8',errors='strict'),parse_int=Token,parse_float=Token)
    numbers=[]
    def walk(v):
        if isinstance(v,Token):numbers.append(str(v))
        elif isinstance(v,list):
            for item in v:walk(item)
        elif isinstance(v,dict):
            for key,item in v.items():
                if key=='bytes' and {'file','sha256','bytes'}<=set(v):continue
                walk(item)
    walk(value)
    return digest(('\n'.join(numbers)).encode('ascii'))


def child(base, name):
    require(isinstance(name, str) and '\\' not in name and ':' not in name, 'portable_relative_path')
    p = PurePosixPath(name)
    require(not p.is_absolute() and all(x not in ('..', '.') for x in p.parts) and p.parts, 'relative_child_required')
    path = base.joinpath(*p.parts)
    current = base
    for part in p.parts:
        current = current / part
        require(not current.is_symlink(), 'symlink_path')
    require(path.resolve().is_relative_to(base.resolve()), 'path_escape')
    return path


def descriptor(base, row, cap=1024*1024):
    path = child(base, row['file'])
    raw = read(path, cap)
    require(len(raw) == row['bytes'] and digest(raw) == row['sha256'].lower(), 'artifact_identity')
    return path, raw


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def write(path, value):
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=True, indent=2, allow_nan=False)
        stream.write('\n')


def filetime_iso(value):
    # FILETIME keeps 100ns resolution; datetime alone only preserves microseconds.
    integer(value, 'creation_filetime', 1)
    seconds, ticks = divmod(value, 10000000)
    dt = datetime(1601,1,1,tzinfo=timezone.utc) + timedelta(seconds=seconds)
    return dt.strftime('%Y-%m-%dT%H:%M:%S') + '.' + str(ticks).zfill(7) + 'Z'


def fresh_identity(seen, record):
    pid = integer(record['pid'],'native_pid',1)
    creation = record['native_creation_utc']
    require(isinstance(creation,str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z',creation), 'native_creation_format')
    identity = (pid,creation)
    require(identity not in seen,'fresh_jvm_identity_reused')
    seen.add(identity)


def jvm_flags(summary):
    args = summary['jvm_arguments']
    require(isinstance(args,list) and all(isinstance(v,str) for v in args),'jvm_arguments_shape')
    required = ['-Xmx512m','-XX:ActiveProcessorCount=2','-XX:-UsePerfData','-da',
                '-Dfile.encoding=UTF-8','-Duser.timezone=UTC','-Djava.awt.headless=true']
    for flag in required:
        require(args.count(flag)==1,'required_jvm_flag:'+flag)
    for prefix in ('-Xmx','-XX:ActiveProcessorCount=','-Dfile.encoding=','-Duser.timezone=','-Djava.awt.headless='):
        require(sum(a.startswith(prefix) for a in args)==1,'conflicting_jvm_flag:'+prefix)
    require(not any(a in ('-ea','-enableassertions','-esa','-enablesystemassertions','-XX:+UsePerfData') or a.startswith(('-ea:','-enableassertions:')) for a in args),'conflicting_jvm_behavior_flag')
    require(summary['available_processors']==2 and summary['assertions_enabled'] is False,'actual_jvm_configuration')
    return {'required_flags':required,'available_processors':2,'heap_cap_is_memory_measurement':False}


def hardware(base, index):
    raw = read(child(base,index['hardware_path']),1024*1024)
    require(digest(raw)==index['hardware_sha256'].lower(),'hardware_sha256')
    value = parse(raw)
    require(value['status'] in ('observed','unavailable'),'hardware_status')
    require(isinstance(value['observation_utc'],str),'hardware_observation_time')
    if value['status']=='observed':
        allowed = {'status','observation_utc','operating_system','processors','machine_capacity','serials_hostnames_usernames_not_collected','load_caveat'}
        require(set(value)==allowed,'hardware_fields')
        require(value['serials_hostnames_usernames_not_collected'] is True,'hardware_privacy_scope')
        require(set(value['operating_system'])=={'Caption','Version','BuildNumber','OSArchitecture','TotalVisibleMemorySize'},'os_capacity_fields')
        require(set(value['machine_capacity'])=={'TotalPhysicalMemory','NumberOfLogicalProcessors'},'machine_capacity_fields')
        require(isinstance(value['processors'],list) and value['processors'],'processor_capacity_rows')
        for cpu in value['processors']:
            require(set(cpu)=={'Name','Manufacturer','NumberOfCores','NumberOfLogicalProcessors','MaxClockSpeed'},'cpu_capacity_fields')
    else:
        require(set(value)<= {'status','observation_utc','reason'},'unavailable_hardware_fields')
    return {'sha256':digest(raw),'metadata':value,'unavailable_not_imputed':True,
            'capacity_metadata_not_idle_host_or_controlled_frequency':True}


def environment(base, index, explicit=None, projection=None):
    """Bind pre-sample class expectations, never derive them from a summary.

    Runtime origins are declared provenance, not filesystem read authority.
    Their original ordered-classpath extraction and canonical inventories are
    independently audited by Root/QA; portable replay needs no private JARs.
    """
    path = explicit or child(base,index['environment_path'])
    raw = read(path,8*1024*1024)
    require(digest(raw)==index['environment_sha256'].lower(),'environment_sha256')
    value = parse(raw)
    require(value['schema_version']==1 and value['status']=='ACTUAL_COMPILED_HARNESS_AND_RUNTIME_BYTECODE_PINS','environment_status')
    require(value['original_build_proof_sha256'].lower()==index['build_proof_sha256'].lower(),'original_build_proof_binding')
    proof_path, proof_raw = descriptor(path.parent,value['build_proof'],8*1024*1024)
    if projection is None:
        require(digest(proof_raw)==value['original_build_proof_sha256'].lower(),'exact_copied_build_proof')
    else:
        require(projection.original_sha(proof_path)==value['original_build_proof_sha256'].lower(),'projected_build_proof_original_identity')
    proof = parse(proof_raw)
    require(proof['status']=='ACTUAL_OWN_HARNESS_COMPILED_NO_MINING_EXECUTION' and proof['native_exit']==0,'actual_compiler_proof')
    require(proof['canonical_readback_before_after'] is True and proof['no_engine_execution'] is True,'compiler_canonical_readback')
    require(value['java_sha256'].lower()==proof['java_sha256'].lower()==JAVA,'environment_java')
    require(value['javac_sha256'].lower()==proof['javac_sha256'].lower()==JAVAC,'environment_javac')
    require(value['ordered_classpath_sha256'].lower()==proof['classpath_sha256'].lower()==CLASSPATH,'environment_ordered_classpath')
    require(value['canonical_miner_proof_sha256'].lower()==MINER_PROOF and value['jdk_file_count']==504,'canonical_runtime_jdk_binding')
    identities=value['class_identities']
    require(set(identities)==set(CLASS_NAMES),'environment_class_set')
    compiled={r['path'].replace('\\','/'):r for r in proof['class_files']}
    require(len(compiled)==len(proof['class_files']),'duplicate_compiled_class')
    for key,name in CLASS_NAMES.items():
        row=identities[key]
        require(row['class']==name and re.fullmatch('[0-9a-fA-F]{64}',row['sha256']),'environment_class_identity')
        require(row['sha256'].lower()==ACTUAL_CLASS_PINS[key],'actual_prepublication_class_pin:'+key)
        integer(row['bytes'],'environment_class_bytes',1)
        for field in ('derivation','origin_path'):
            require(isinstance(row[field],str) and row[field],'environment_origin_metadata')
        require(re.fullmatch('[0-9a-fA-F]{64}',row['origin_sha256']),'environment_origin_sha256')
        require(row['member']==name.replace('.','/')+'.class','environment_class_resource_member')
        if key in ('harness_identity','xes_observer_identity'):
            matching=compiled.get(row['member'])
            require(matching is not None and matching['sha256'].lower()==row['sha256'].lower() and matching['bytes']==row['bytes'],'compiled_observer_class_binding')
    require(identities['algorithm_identity']['sha256'].lower()=='e8535a6b65b7e758a49e757d635e8797071b8e860bc8d1c6859e592eb1ee21ad','unchanged_algorithm_class')
    return identities, {'descriptor_sha256':digest(raw),'original_build_proof_sha256':value['original_build_proof_sha256'].lower(),
                       'published_build_proof_sha256':digest(proof_raw),
                       'java_sha256':JAVA,'javac_sha256':JAVAC,'ordered_classpath_sha256':CLASSPATH,
                       'canonical_miner_proof_sha256':MINER_PROOF,'jdk_file_count':504,
                       'class_identities':identities,'runtime_origin_paths_not_read_authority':True,
                       'canonical_origin_extraction_requires_independent_native_provenance_audit':True}


def observed_classes(summary, expected):
    for key,name in CLASS_NAMES.items():
        require(key in expected,'missing_predeclared_class_identity')
        actual=summary[key]
        require(actual['class']==expected[key]['class']==name and actual['sha256'].lower()==expected[key]['sha256'].lower(),'observed_class_binding:'+key)


def native(base, relative, projection=None):
    path = child(base, relative)
    require(path.name.endswith('.process.json'), 'native_record_suffix')
    raw = read(path, 1024*1024); record = parse(raw)
    streams = {}
    stem = path.name[:-len('.process.json')]
    for stream in ('stdout', 'stderr'):
        published_path=path.with_name(stem+'.'+stream)
        raw_path=path.with_name(stem+'.raw.'+stream) if projection is not None else published_path
        data = read(raw_path, 8*1024*1024)
        require(len(data) == record[stream+'_bytes_persisted'], 'stream_length')
        require(digest(data) == record[stream+'_sha256'].lower(), 'stream_sha256')
        require(record[stream+'_complete'] is True, 'stream_incomplete')
        if projection is not None:
            raw_entry=projection.entry(raw_path)
            require(raw_entry['preserved_original_capture'] is True and raw_entry['original_sha256'].lower()==raw_entry['published_sha256'].lower()==digest(data),'original_raw_capture_identity')
            require(raw_entry['source_path']==published_path.relative_to(projection.base).as_posix(),'raw_capture_source_mapping')
            projected=read(published_path,8*1024*1024)
            projected_entry=projection.entry(published_path)
            require(digest(projected)==projected_entry['published_sha256'].lower() and len(projected)==projected_entry['published_bytes'],'projected_stream_identity')
            require(projected_entry['original_sha256'].lower()==digest(data) and projected_entry['original_bytes']==len(data),'projected_capture_original_binding')
            require(stream=='stdout' or projected==data,'stderr_must_remain_raw')
            if stream=='stdout':protocol_projection_binding(data,projected)
            streams[stream]=projected
        else:
            streams[stream] = data
    require(record['native_exit'] == 0 and all(record[k] is False for k in ('output_limit','capture_fault','drain_timeout')), 'native_failure')
    require(record['program_sha256'].lower() == JAVA, 'actual_java_binary')
    return record, streams, digest(raw)


def protocol_projection_binding(original,projected):
    """Use preserved actual console bytes, not only map self-attestation."""
    old_lines=original.splitlines(keepends=True);new_lines=projected.splitlines(keepends=True)
    require(len(old_lines)==len(new_lines),'projected_console_line_count')
    allowed={'terminal_ready','summary','ledger'}
    for old,new in zip(old_lines,new_lines):
        if not old.startswith(b'S20_PROTOCOL '):
            require(old==new,'projected_nonprotocol_console_change');continue
        require(new.startswith(b'S20_PROTOCOL '),'projected_protocol_prefix')
        before=parse(old[13:]);after=parse(new[13:])
        if before.get('phase')=='TERMINAL_READY':
            require(set(before)==set(after),'projected_protocol_field_set')
            for key in allowed:
                require(key in before and set(before[key])==set(after[key])=={'file','sha256','bytes'},'projected_protocol_descriptor_shape')
                require(before[key]['file']==after[key]['file'],'projected_protocol_artifact_name')
                require(isinstance(after[key]['sha256'],str) and re.fullmatch('[0-9a-fA-F]{64}',after[key]['sha256']),'projected_protocol_artifact_sha')
                integer(after[key]['bytes'],'projected_protocol_artifact_bytes')
            require({k:v for k,v in before.items() if k not in allowed}=={k:v for k,v in after.items() if k not in allowed},'projected_protocol_identity_or_value_change')
            # Every non-descriptor numeric/string token must remain lexically
            # identical too, not merely equal after Decimal parsing.
            def outside_descriptors(raw):
                class Token(str):pass
                value=json.loads(raw.decode('utf-8',errors='strict'),parse_int=Token,parse_float=Token)
                return {k:v for k,v in value.items() if k not in allowed}
            require(outside_descriptors(old[13:])==outside_descriptors(new[13:]),'projected_protocol_numeric_lexeme_change')
            def descriptor_skeleton(line):
                for key in sorted(allowed):
                    pattern=rb'("'+key.encode('ascii')+rb'"\s*:\s*)\{[^{}]*\}'
                    line,count=re.subn(pattern,lambda match:match[1]+b'{DESCRIPTOR}',line)
                    require(count==1,'protocol_descriptor_span')
                return line
            require(descriptor_skeleton(old)==descriptor_skeleton(new),'projected_protocol_nondescriptor_bytes')
        else:
            require(old==new,'projected_boot_protocol_change')


def protocols(stdout):
    records = []
    for line in stdout.decode('utf-8',errors='strict').splitlines():
        if line.startswith('S20_PROTOCOL '):
            require(len(line) <= 65536, 'protocol_line_cap')
            records.append(parse(line[13:].encode('utf-8')))
    require([x['phase'] for x in records] == ['BOOT_READY','TERMINAL_READY'], 'protocol_order_or_duplicates')
    return records


def quality_audit(directory):
    """Re-run the existing pure saved-evidence audit, never metric engines."""
    q = ROOT/'evidence/sprint19/miner-quality'
    for filename, expected in QUALITY_SOURCES.items():
        require(digest(read(Path(__file__).with_name(filename))) == expected, 'historical_pure_audit_source_pin')
    manifest_raw = read(q/'manifest.json')
    require(digest(manifest_raw) == QUALITY_MANIFEST, 'historical_manifest_pin')
    manifest = parse(manifest_raw)
    seen = set()
    for row in manifest['files']:
        require(row['path'] not in seen, 'historical_duplicate_file'); seen.add(row['path'])
        descriptor(q, {'file':row['path'],'bytes':row['bytes'],'sha256':row['sha256']}, 32*1024*1024)
    actual = {p.relative_to(q).as_posix() for p in q.rglob('*') if p.is_file()}
    require(actual == seen | {'manifest.json'}, 'historical_manifest_file_set')
    audit = module('saved_cohort_audit', 'audit-quality-cohort.py')
    output = directory/'historical-quality-audit.json'
    old = sys.argv
    try:
        sys.argv = ['audit-quality-cohort','--corpus',str(q/'prepared/inputs/corpus.json'),
                    '--prepared',str(q/'prepared'),'--conversion',str(q/'reference-conversion'),
                    '--rust',str(q/'rust-metrics.json'),'--reference',str(q/'reference-metrics.json'),
                    '--output',str(output)]
        with contextlib.redirect_stdout(io.StringIO()):
            audit.main()
    finally:
        sys.argv = old
    result = load(output)
    require(result['status'] == 'independent_eight_row_miner_cohort_audit_passed', 'historical_pure_audit')
    typed = load(q/'typed-comparison.json')
    return {r['id']:r for r in typed['cases']}, {
        'manifest_sha256':QUALITY_MANIFEST,'pure_audit_sha256':digest(read(output)),
        'pure_audit_source_sha256':digest(read(Path(__file__).with_name('audit-quality-cohort.py'))),
        'status':result['status'],'fresh_metrics':False}


def stats(samples):
    values = sorted(x['engine_time_nanos'] for x in samples)
    # Exact rational median (never lossy float conversion of nanosecond integers).
    n = len(values)
    median = None if not n else {'numerator': values[n//2] if n%2 else values[n//2-1]+values[n//2], 'denominator':1 if n%2 else 2}
    return {'sample_count':n,'sample_ids':[x['call_id'] for x in samples],
            'raw_engine_nanos':[x['engine_time_nanos'] for x in samples],
            'min_nanos':values[0] if n else None,'median_nanos_exact':median,'max_nanos':values[-1] if n else None}


def audit(corpus_path, index_path, semantic_directory, environment_path=None, public_projection=None):
    corpus_raw = read(corpus_path); require(digest(corpus_raw) == CORPUS, 'frozen_corpus_pin')
    corpus = parse(corpus_raw); index_raw = read(index_path); index = parse(index_raw)
    projection=PublicProjection(public_projection) if public_projection is not None else None
    if projection is not None:projection.entry(index_path)
    require(index['corpus_sha256'].lower() == CORPUS and index['method_sha256'].lower() == corpus['method_sha256'], 'index_method_binding')
    require(corpus['optional_alphappp']['enabled'] is False, 'no_optional_algorithm')
    require(digest(read(Path(__file__).with_name('audit-miner-performance.py'))) == SEMANTIC_SOURCE, 'semantic_auditor_source_pin')
    semantic = module('benchmark_semantic_auditor','audit-miner-performance.py')
    cases = {c['id']:c for c in corpus['cases']}
    require(len(cases) == 8 and len(corpus['process_order']) == 32, 'frozen_schedule_shape')
    errors = []; process_reports = []; call_reports = []; semantic_count = 0; identities = set()
    try:
        expected_classes, environment_proof = environment(index_path.parent,index,environment_path,projection)
    except Exception as error:
        expected_classes={};environment_proof={'status':'invalid_or_unavailable','reason':str(error)}
        errors.append({'scope':'environment','reason':str(error)})
    try:
        hardware_proof = hardware(index_path.parent,index)
    except Exception as error:
        hardware_proof = {'status':'invalid','reason':str(error)}
        errors.append({'scope':'hardware','reason':str(error)})
    rows = index['processes']; expected_ids = [p['process_id'] for p in corpus['process_order']]
    actual_ids = [r['process_id'] for r in rows]
    require(len(actual_ids) == len(set(actual_ids)), 'duplicate_process')
    require(actual_ids == expected_ids[:len(actual_ids)], 'process_order_or_extra_attempt')
    rowmap = {r['process_id']:r for r in rows}
    try:
        historical, historical_proof = quality_audit(semantic_directory)
    except Exception as error:
        historical = {}; historical_proof = {'status':'unavailable','reason':str(error)}
        errors.append({'scope':'historical_quality','reason':str(error)})
    for scheduled in corpus['process_order']:
        pid = scheduled['process_id']; case = cases[scheduled['case_id']]
        pending = {r['call_id']:{'call_id':r['call_id'],'case_id':case['id'],'process_id':pid,
                   'regime':scheduled['regime'],'role':r['role'],'status':'unexecuted',
                   'engine_time_nanos':None,'semantic_equal':False} for r in scheduled['iterations']}
        report = {'process_id':pid,'case_id':case['id'],'regime':scheduled['regime'],'valid':False}
        try:
            require(pid in rowmap, 'scheduled_process_unexecuted')
            trial = rowmap[pid]
            require(trial['case_id'] == case['id'] and trial['regime'] == scheduled['regime'], 'trial_identity')
            require(trial['scheduled_calls'] == scheduled['iterations'], 'scheduled_call_manifest')
            resultdir = child(index_path.parent,trial['result_directory'])
            source = read(child(corpus_path.parent,case['file']),1024*1024)
            require(digest(source) == case['sha256'], 'input_bytes_pin')
            # Partial trials may lack a summary; recover each completed observation
            # from its forced ledger, without declaring the native trial complete.
            ledger_path = resultdir/'iteration-ledger.jsonl'
            ledger_raw = read(ledger_path,1024*1024)
            ledger = [parse(line) for line in ledger_raw.splitlines() if line]
            require(len(ledger) <= 2*len(pending), 'ledger_size')
            for event in ledger:
                if event.get('event') == 'call_started' and event.get('call_id') in pending:
                    pending[event['call_id']]['status'] = 'started_without_completed_observation'
            # Retain every independently readable completed observation even
            # when another call later fails a conservation/native predicate.
            for event in ledger:
                if event.get('event') == 'call_completed' and event.get('call_id') in pending:
                    try:
                        _, observed_raw = descriptor(resultdir,event['observation'])
                        observed = parse(observed_raw)
                        pending[event['call_id']].update(
                            status=observed['status'],engine_invoked=observed.get('engine_invoked'),
                            engine_time_nanos=observed.get('engine_time_nanos'),
                            observation_sha256=digest(observed_raw),exception=observed.get('exception'))
                    except Exception as error:
                        pending[event['call_id']]['observation_read_error'] = str(error)
            started = []; completed = []
            for event in ledger:
                if event['event'] == 'call_started':
                    started.append(event['call_id'])
                elif event['event'] == 'call_completed':
                    completed.append(event['call_id'])
                    require(completed == started[:len(completed)], 'ledger_completion_order')
                    _, raw = descriptor(resultdir,event['observation'])
                    obs = parse(raw); call = obs['call_id']
                    require(call == event['call_id'] and call in pending, 'call_identity')
                    expected = next(x for x in scheduled['iterations'] if x['call_id'] == call)
                    require(obs['process_id'] == pid and obs['case_id'] == case['id'] and obs['role'] == expected['role'] and obs['ordinal_in_process'] == expected['ordinal_in_process'], 'call_schedule_fields')
                    require(obs['input_sha256'] == case['sha256'], 'call_input_binding')
                    require(event['status'] == obs['status'], 'ledger_status')
                    item = pending[call]
                    item.update(status=obs['status'],observation_sha256=digest(raw),exception=obs.get('exception'),
                                engine_invoked=obs['engine_invoked'],engine_time_nanos=obs['engine_time_nanos'])
                    require(obs['engine_invoked'] is True, 'engine_not_invoked')
                    integer(obs['engine_time_nanos'],'engine_time_nanos')
                    require(obs['input_traces'] == case['trace_count'] and obs['input_events'] == case['event_count'], 'input_counts')
                    require(obs['input_xlog_unchanged'] is True and obs['input_xlog_before_sha256'] == obs['input_xlog_after_sha256'], 'typed_input_hash_conservation')
                    require(obs['input_xlog_before'] == obs['input_xlog_after'], 'typed_input_field_conservation')
                    model = obs['input_xlog_before']
                    require(model['trace_count'] == len(model['traces']) == case['trace_count'], 'full_trace_count')
                    require(model['event_count'] == sum(len(t['events']) for t in model['traces']) == case['event_count'], 'full_event_count')
                    variants = []
                    for trace in model['traces']:
                        labels = []
                        for event_model in trace['events']:
                            names = [a for a in event_model['attributes'] if a['key']=='concept:name']
                            require(len(names)==1 and names[0]['type']=='string', 'actual_event_name_attribute')
                            labels.append(names[0]['value'])
                        variants.append(''.join(labels))
                    require(variants == case['training_variants'], 'full_ordered_input_variant_identity')
                    item['typed_input_conserved'] = True
                    if 'bpmn' in obs:
                        _, bpmn = descriptor(resultdir,obs['bpmn'])
                        old_desc = case['historical_bpmn']; require(old_desc is not None, 'unexpected_empty_log_model')
                        baseline = read(child(ROOT,old_desc['repository_path']),4*1024*1024)
                        require(digest(baseline) == old_desc['sha256'] and len(baseline) == old_desc['bytes'], 'historical_same_case_bpmn')
                        proof = semantic.compare(baseline,bpmn)
                        # Auditor wall time is instrumentation, not a semantic
                        # derived field. Omit only it for deterministic replay.
                        proof.pop('audit_wall_seconds',None)
                        write(semantic_directory/(call+'.semantic.json'),proof)
                        item.update(semantic_equal=proof['semantic_equal'],semantic_status=proof['status'],
                                    semantic_map=call+'.semantic.json',bpmn_sha256=digest(bpmn),historical_bpmn_sha256=digest(baseline))
                        require(proof['semantic_equal'] is True, 'full_semantic_bijection_failed')
                        semantic_count += 1
                    else:
                        require(case['id'] == 'empty-log' and obs['status'] == 'algorithm_exception', 'unexpected_no_model')
                        require(obs['exception']['root']['class'] == case['historical_outcome_hypothesis']['exception']['class'], 'empty_exception_class')
                        require('partial_bpmn' not in obs, 'failed_partial_model')
                else:
                    raise ValueError('unknown_ledger_event')
            require(started == list(pending)[:len(started)] and len(started) == len(set(started)), 'ledger_start_order')
            require(completed == list(pending), 'incomplete_iteration_ledger')
            native_record, streams, native_sha = native(index_path.parent,trial['native_record_path'],projection)
            fresh_identity(identities,native_record)
            protocol = protocols(streams['stdout']); boot, terminal = protocol
            require(trial['terminal'] == terminal, 'terminal_index_binding')
            _, ready_raw = descriptor(resultdir,terminal['terminal_ready'],65536)
            ready = parse(ready_raw)
            _, summary_raw = descriptor(resultdir,terminal['summary'],8*1024*1024)
            summary = parse(summary_raw)
            descriptor(resultdir,terminal['ledger'])
            require(terminal['ledger']['sha256'] == digest(ledger_raw), 'terminal_ledger_binding')
            for v in (boot,terminal,ready,summary):
                require(v['process_id'] == pid and v['pid'] == native_record['pid'] and v['nonce'] == boot['nonce'], 'pid_nonce_binding')
            require(isinstance(boot['nonce'],str) and re.fullmatch('[A-Za-z0-9-]{16,128}',boot['nonce']), 'protocol_nonce_shape')
            require(ready['summary'] == terminal['summary'] and ready['ledger'] == terminal['ledger'], 'ready_summary_binding')
            require(summary['input_sha256'] == case['sha256'] and summary['parameters'] == corpus['parameters'], 'summary_input_parameters')
            require(summary['algorithm_identity']['class'] == corpus['algorithm_class'] and summary['algorithm_identity']['sha256'] == corpus['algorithm_class_sha256'], 'actual_algorithm_class')
            require(summary['regime'] == ('cold' if scheduled['regime']=='cold-fresh-jvm' else 'warm'), 'summary_regime')
            require(summary['assertions_enabled'] is False, 'assertion_flags')
            report['jvm_configuration'] = jvm_flags(summary)
            observed_classes(summary,expected_classes)
            report['observed_class_identities'] = {key:summary[key] for key in ('algorithm_identity','parser_identity','exporter_identity','harness_identity','xes_observer_identity')}
            require([x['call_id'] for x in summary['iterations']] == list(pending), 'summary_call_order')
            for obs in summary['iterations']:
                require(parse(read(resultdir/(obs['call_id']+'.json'),1024*1024)) == obs, 'summary_full_observation_binding')
            require(summary['scheduled_calls'] == summary['completed_calls'] == terminal['scheduled_calls'] == terminal['completed_calls'] == len(pending), 'summary_call_counts')
            names = set()
            for artifact in summary['artifacts']:
                require(artifact['file'] not in names, 'duplicate_artifact'); names.add(artifact['file'])
                descriptor(resultdir,artifact)
            require(names == {call+'.json' for call in pending} | {call+'.bpmn' for call,item in pending.items() if item['semantic_equal']}, 'artifact_exact_set')
            live = load(child(index_path.parent,trial['live_counters_path']),1024*1024)
            boot_counters = load(resultdir.parent/'boot-counters.json',1024*1024)
            require(live['terminal'] == terminal and boot_counters['protocol'] == boot, 'counter_protocol_binding')
            creation = native_record['native_creation_utc']
            for counter in (live,boot_counters):
                require(counter['native_creation_utc'] == creation, 'counter_creation_identity')
                require(filetime_iso(counter['process_cpu']['creation_filetime_100ns']) == creation, 'native_filetime_creation')
                require(counter['process_cpu']['exit_filetime_100ns'] is None, 'counter_not_live')
            frequency = integer(trial['stopwatch_frequency'],'stopwatch_frequency',1)
            require(live['stopwatch_frequency'] == frequency, 'stopwatch_units')
            for key in ('boot_ready_ticks','go_dispatch_ticks','terminal_ready_ticks'):
                require(live[key] == trial[key], 'live_controller_time_binding')
            ticks = [integer(trial[k],k) for k in ('boot_ready_ticks','go_dispatch_ticks','terminal_ready_ticks','exit_dispatch_ticks','instrumented_process_lifetime_ticks','controller_including_capture_drain_ticks')]
            require(ticks == sorted(ticks), 'controller_time_order')
            require(ticks[3]-ticks[2] <= 10*frequency, 'terminal_hold_bound')
            require(ticks[4] <= (scheduled['timeout_seconds']+10)*frequency, 'process_timeout_bound')
            after = trial['process_cpu_after_exit']
            require(after['creation_filetime_100ns'] == live['process_cpu']['creation_filetime_100ns'], 'postexit_process_identity')
            integer(after['exit_filetime_100ns'],'native_exit_filetime',after['creation_filetime_100ns'])
            for key in ('user_cpu_100ns','kernel_cpu_100ns'):
                values = [integer(c['process_cpu'][key],key) for c in (boot_counters,live)] + [integer(after[key],key)]
                require(values == sorted(values), 'cpu_monotonicity')
            memory = live['process_memory']
            for key in ('peak_working_set_bytes','current_working_set_bytes','peak_private_commit_bytes','current_private_commit_bytes','page_faults'):
                integer(memory[key],key)
            require(memory['peak_working_set_bytes'] >= memory['current_working_set_bytes'] and memory['peak_private_commit_bytes'] >= memory['current_private_commit_bytes'], 'memory_highwater_order')
            for key in ('peak_working_set_bytes','peak_private_commit_bytes'):
                require(integer(boot_counters['process_memory'][key],key) <= memory[key], 'memory_highwater_monotonicity')
            for counter in (boot_counters['job'],live['job'],trial['job_after_exit']):
                for key in ('peak_job_commit_bytes','peak_single_process_commit_bytes','user_cpu_100ns','kernel_cpu_100ns','total_processes','active_processes','limit_terminated_processes','page_faults'):
                    integer(counter[key],key)
            for key in ('peak_job_commit_bytes','peak_single_process_commit_bytes','user_cpu_100ns','kernel_cpu_100ns','total_processes','page_faults'):
                values = [counter[key] for counter in (boot_counters['job'],live['job'],trial['job_after_exit'])]
                require(values == sorted(values), 'job_counter_monotonicity')
            require(trial['job_after_exit']['active_processes'] == 0, 'job_descendant_still_active')
            require(trial['status'] == 'completed' and trial['failure'] is None, 'controller_trial_failed')
            report.update(valid=True,native_record_sha256=native_sha,pid=native_record['pid'],
                          native_creation_filetime_100ns=after['creation_filetime_100ns'],
                          native_exit_filetime_100ns=after['exit_filetime_100ns'],
                          native_lifetime_100ns=after['exit_filetime_100ns']-after['creation_filetime_100ns'],
                          process_terminal_memory=memory,process_cpu_after_exit=after,
                          job_after_exit=trial['job_after_exit'],live_job=live['job'],
                          controller_ticks={k:trial[k] for k in ('stopwatch_frequency','boot_ready_ticks','go_dispatch_ticks','terminal_ready_ticks','exit_dispatch_ticks','instrumented_process_lifetime_ticks','controller_including_capture_drain_ticks')},
                          active_pipeline_nanos=integer(ready['active_pipeline_nanos'],'active_pipeline_nanos'),
                          stdout_sha256=native_record['stdout_sha256'],stderr_sha256=native_record['stderr_sha256'],
                          stdout_bytes=native_record['stdout_bytes_persisted'],stderr_bytes=native_record['stderr_bytes_persisted'])
        except Exception as error:
            report['reason'] = str(error)
            errors.append({'scope':pid,'reason':str(error)})
        process_reports.append(report); call_reports.extend(pending.values())
    groups = []
    for case in cases.values():
        for regime in ('cold-fresh-jvm','warm-same-jvm'):
            samples = [r for r in call_reports if r['case_id']==case['id'] and r['regime']==regime and r['role']=='measured']
            timed = [r for r in samples if type(r['engine_time_nanos']) is int]
            success = [r for r in timed if r['status'] in ('diagram_returned','bare_dfg_fallback_returned')]
            failure = [r for r in timed if r not in success]
            groups.append({'case_id':case['id'],'regime':regime,'scheduled_sample_ids':[r['call_id'] for r in samples],
                           'successful_engine_calls':stats(success),'failed_engine_calls':stats(failure),
                           'untimed_or_unexecuted_sample_ids':[r['call_id'] for r in samples if r not in timed]})
    complete = not errors and len(call_reports)==64 and semantic_count==56 and all(p['valid'] for p in process_reports)
    carry = []
    for case in cases.values():
        selected = [r for r in call_reports if r['case_id']==case['id']]
        allowed = complete and case['id'] in ADMITTED and len(selected)==8 and all(r['semantic_equal'] for r in selected)
        row = historical.get(case['id'])
        if allowed:
            try:
                require(row == case['quality_carry_gate']['historical_row'],'same_historical_quality_row')
                require(row['status']=='same_saved_net_metric_components_agree','historical_metric_admission')
                q = ROOT/'evidence/sprint19/miner-quality/prepared/nets'/ (case['id']+'.net.json')
                require(digest(read(q)) == row['net_sha256'],'saved_quality_net_identity')
            except Exception as error:
                allowed=False;errors.append({'scope':case['id']+'_carry','reason':str(error)})
        carry.append({'case_id':case['id'],'quality_carry_permitted':allowed,
                      'historical_training_only_row':row if allowed else None,
                      'reason':'same_saved_historical_quality_after_all_56_maps' if allowed else ('unsupported_loop_or_empty_exception_no_scalar' if case['id'] not in ADMITTED else 'required_evidence_not_complete'),
                      'fresh_metric_measurement':False})
    if errors:
        for row in carry:
            row.update(quality_carry_permitted=False,historical_training_only_row=None)
    return {'schema_version':1,'status':'COMPLETE_FROZEN_BENCHMARK_AND_CONDITIONAL_HISTORICAL_CARRY' if complete and not errors else 'INCOMPLETE_OR_INVALID_BENCHMARK_NO_CARRY',
            'corpus_sha256':CORPUS,'index_sha256':digest(index_raw),'method_sha256':corpus['method_sha256'],
            'semantic_auditor_source_sha256':SEMANTIC_SOURCE,
            'publication_projection':None if projection is None else {
                'manifest_sha256':projection.manifest_sha256,
                'original_index_sha256':projection.original_sha(index_path),
                'published_index_sha256':digest(index_raw),
                'raw_native_capture_counts_and_hashes_preserved':True,
                'protocol_stream_is_projected_not_raw':True,
                'independent_original_to_public_scientific_comparison_required':True},
            'hardware':hardware_proof,'unique_process_creation_identities':len(identities),
            'environment':environment_proof,
            'required_processes':32,'required_calls':64,'observed_processes':len(rows),
            'completed_call_rows':sum('observation_sha256' in r for r in call_reports),
            'unexecuted_call_rows':sum(r['status']=='unexecuted' for r in call_reports),
            'started_without_completed_rows':sum(r['status']=='started_without_completed_observation' for r in call_reports),
            'full_semantic_maps':semantic_count,
            'processes':process_reports,'calls':call_reports,'timing_groups':groups,'historical_quality_audit':historical_proof,
            'quality_carry':carry,'errors':errors,'whole_R5_accepted':False,'splitminer_rust_port_or_speedup_claim':False,
            'scope':'Tiny frozen synthetic inputs; warmups retained but excluded from primary timing only by frozen role. Native process peaks through terminal include startup and all calls; Job counters begin assignment and include descendants. Heap cap is not RAM. Fresh JVM is not cold OS cache. No forced GC, outlier removal, significance or production-capacity claim.'}


def main():
    require(__debug__, 'audit_requires_assertions_enabled')
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('corpus','index','output'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--semantic-directory',type=Path)
    parser.add_argument('--environment',type=Path,help='Optional explicit location of the index-hash-bound environment descriptor')
    parser.add_argument('--public-projection',type=Path,help='Explicit complete dual-identity public projection manifest; private mode is unchanged')
    args = parser.parse_args()
    require(not args.output.exists(),'fresh_output_required')
    directory = args.semantic_directory or args.output.with_name(args.output.stem+'-semantics')
    directory.mkdir(exist_ok=False)
    report = audit(args.corpus,args.index,directory,args.environment,args.public_projection)
    # Decimal input values are only carried historical scalar fields; these
    # frozen scores are strings. Refuse accidental numeric re-encoding instead
    # of converting a future unhandled Decimal to a rounded float/string.
    write(args.output,report)
    print(json.dumps({'status':report['status'],'calls':len(report['calls']),'full_semantic_maps':report['full_semantic_maps'],'output_sha256':digest(read(args.output))}))


if __name__ == '__main__':
    main()
