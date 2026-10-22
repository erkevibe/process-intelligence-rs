"""Verify saved incomplete evidence, never execute product/database/network."""
import csv
import hashlib
import io
import json
from pathlib import Path
import sys
import time
import xml.etree.ElementTree as ET

inputs, measured, output = map(Path, sys.argv[1:4])
projection = Path(sys.argv[4]) if len(sys.argv) == 5 else None
started = time.monotonic()
APP = '4121BD68F1C0C05A61B039FADF20FEC5C2DA4379D8AAAFB170DC3B43861D1525'
MANIFEST = '59DA6F7A7A61826A579F93C394D1EFDF7DDEBE9D550E8120E1BB1EF8D5BDCC43'
STAMP = '2026-01-01T00:00:00.000000001Z'

def need(value, label):
    if not value:
        raise ValueError(label)

def read(path, cap=25*1024*1024):
    need(time.monotonic()-started < 60, 'audit deadline')
    need(path.is_file() and not path.is_symlink() and path.stat().st_size <= cap, 'bounded regular saved file')
    raw = path.read_bytes()
    need(len(raw) <= cap, 'saved byte cap')
    return raw

def sha(raw):
    return hashlib.sha256(raw).hexdigest().upper()

def load(path, cap=25*1024*1024):
    return json.loads(read(path, cap))

entries = load(projection)['entries'] if projection else []
omitted = []

def original(path, digest, size):
    if path.exists():
        raw = read(path)
        need(len(raw) == size and sha(raw) == digest.upper(), 'original bytes/hash')
    else:
        need(projection is not None, 'private original missing')
        relative = path.relative_to(projection.parent).as_posix()
        found = [e for e in entries if e['public_path'] == relative and e['mode'] == 'omit']
        need(len(found) == 1 and found[0]['original_sha256'].upper() == digest.upper()
             and found[0]['original_bytes'] == size, 'explicit omitted original stream')
        omitted.append(relative)

manifest_raw = read(inputs/'manifest.json', 65536)
need(sha(manifest_raw) == MANIFEST, 'prospective manifest exact')
manifest = json.loads(manifest_raw)
need(manifest['app_sha256'] == APP and manifest['no_converter_invoked'] is True, 'immutable app')
need([(c['id'], c['events']) for c in manifest['cases']] == [('CMP10K', 10000), ('CMP90K', 90000)], 'fixed two planned counts')
for case in manifest['cases']:
    original(inputs/case['input_file'], case['input_sha256'], case['input_bytes'])
    original(inputs/case['oracle_file'], case['oracle_sha256'], len(read(inputs/case['oracle_file'], 65536)))
need(not (measured/'cmp90k-http'/'result.json').exists(), '90K result must be absent')
need(not (measured/'complexity-measure-proof.json').exists(), 'whole success proof must be absent')
unknown_specs = [('postgres', 23044, '2026-10-22T22:30:40.6305015Z'),
                 ('cmp90k-app-only-process', 39988, '2026-10-22T22:30:55.1979278Z'),
                 ('cmp90k-one-conversion', 41888, '2026-10-22T22:30:57.3754013Z')]
unknowns = []
for label, pid, creation in unknown_specs:
    record = load(measured/(label+'.start.json'), 65536)
    need(record['pid'] == pid and record['native_creation_utc'] == creation, 'original unknown start identity')
    need(not (measured/(label+'.process.json')).exists(), 'missing original completion remains missing')
    unknowns.append({'label': label, 'pid': pid, 'creation_utc': creation,
                     'native_exit': 'UNKNOWN', 'stream_eof': 'UNKNOWN'})
captures = []
for path in sorted(measured.glob('*.process.json')):
    record = load(path, 65536)
    label = path.name.removesuffix('.process.json')
    need(record['native_exit'] is not None and record['stdout_complete'] and record['stderr_complete'], 'existing native closure')
    need(not any(record.get(k) for k in ('output_limit', 'capture_fault', 'drain_timeout')), 'capture fault')
    for side in ('stdout', 'stderr'):
        original(measured/(label+'.'+side), record[side+'_sha256'], record[side+'_bytes_persisted'])
    captures.append({'label': label, 'pid': record['pid'], 'exit': record['native_exit']})
need(len(captures) == 7, 'exact seven completed original captures')
need(any(c['label'] == 'command' and c['pid'] == 40132 and c['exit'] == 1 for c in captures), 'failed worker retained')
case = manifest['cases'][0]
source = read(inputs/case['input_file'])
tree = ET.fromstring(source)
local = lambda n: n.tag.rsplit('}', 1)[-1]
traces = [n for n in tree if local(n) == 'trace']
need(len(traces) == 1, 'one manual trace')
need([(n.attrib.get('key'), n.attrib.get('value')) for n in traces[0] if local(n) == 'string'] == [('concept:name', 'complexity-case')], 'trace fields')
events = [n for n in traces[0] if local(n) == 'event']
need(len(events) == 10000 and all([(local(n), n.attrib.get('key'), n.attrib.get('value')) for n in event] == [('string', 'concept:name', 'A'), ('date', 'time:timestamp', STAMP)] for event in events), 'independent fixed 10K XES')
result = load(measured/'cmp10k-http'/'result.json', 4*1024*1024)
need(result['status'] == 'OBSERVATION_COMPLETED' and result['case'] == 'CMP10K'
     and result['submitted_conversions'] == 1 and result['app_sha256'] == APP
     and result['input_manifest_sha256'] == MANIFEST and result['input_sha256'] == sha(source), 'one fixed actual 10K')
meta = result['metadata']
need(meta['snapshot']['state'] == 'completed' and meta['allow_loss'] is False, '10K completed loss policy')
saved = load(measured/'cmp10k-retained-source-readonly.stdout')
need(saved['metadata'] == meta and saved['record']['kind'] == 'conversion'
     and saved['record']['resource_id'] == result['artifact_id'] == meta['artifact_id'], 'durable/HTTP metadata identity')
heavy = saved['record']['document']
need(heavy['id'] == result['artifact_id'] and heavy['input'].encode('utf-8') == source, 'retained actual source')
payload = read(measured/'cmp10k-http'/'payload.bin')
report_raw = read(measured/'cmp10k-http'/'report.bin', 4*1024*1024)
need(heavy['payload'].encode('utf-8') == payload and heavy['report'].encode('utf-8') == report_raw, 'actual durable pair')
rows = list(csv.reader(io.StringIO(payload.decode('utf-8'), newline=''), strict=True))
need(rows[0] == ['case', 'activity', 'timestamp', 'lifecycle'] and len(rows) == 10001
     and all(row == ['complexity-case', 'A', STAMP, ''] for row in rows[1:]), 'manual 10K CSV')
report = json.loads(report_raw)
need(meta['source_sha256'].upper() == sha(source) and meta['input_bytes'] == len(source)
     and meta['payload_sha256'].upper() == sha(payload) and meta['report_sha256'].upper() == sha(report_raw), 'metadata byte binding')
need(report['status'] == 'converted' and report['input_sha256'].upper() == sha(source)
     and report['input_bytes'] == len(source) and report['target_sha256'].upper() == sha(payload)
     and report['target_bytes'] == len(payload) and report['allow_metadata_loss'] is False, 'report binding')
evidence = report['evidence']
need(evidence['trace_count'] == 1 and evidence['event_count'] == 10000
     and evidence['metadata_loss_count'] == 0 and evidence['losses'] == [], 'manual report counts')
for core in (evidence['source_core'], evidence['target_core']):
    need(len(core['traces']) == 1 and core['traces'][0]['name'] == 'complexity-case'
         and len(core['traces'][0]['events']) == 10000
         and all(e == {'activity': 'A', 'timestamp': STAMP, 'lifecycle': None} for e in core['traces'][0]['events']), 'manual report core')
samples = load(measured/'cmp10k-one-conversion-memory-samples.json')
need(samples['sampling_not_continuous'] is True and samples['intended_poll_ms'] == 50, 'memory scope')
need(len(samples['samples']) == 117 and {(s['pid'], s['native_creation_utc']) for s in samples['samples']} == {(21896, '2026-10-22T22:30:43.4701176Z')}, 'original memory identity')
app = load(measured/'cmp10k-app-only-process.process.json', 65536)
need(app['pid'] == 21896 and app['program_sha256'] == APP and app['native_creation_utc'] == '2026-10-22T22:30:43.4701176Z', 'immutable captured app')
keys = ('current_working_set_bytes', 'current_private_commit_bytes', 'peak_working_set_bytes', 'peak_private_commit_bytes')
need(all(type(s['counters'][k]) is int and s['counters'][k] >= 0 for s in samples['samples'] for k in keys), 'native memory counters')
need(not output.exists(), 'fresh audit output')
output.write_text(json.dumps({'status': 'INDEPENDENT_FAILED_INCOMPLETE_STAGE_EVIDENCE_VERIFIED',
    'stage_success': False, 'two_case_acceptance': False, 'verified_successful_subscope': 'CMP10K_ONLY',
    'completed_original_captures': captures, 'permanent_unknowns': unknowns, 'cmp90k_result_absent': True,
    'input_manifest_sha256': MANIFEST, 'cmp10k_rows': 10000,
    'cmp10k_sample_count': 117, 'memory_maxima': {k: max(s['counters'][k] for s in samples['samples']) for k in keys},
    'public_omitted_original_streams': omitted,
    'limitations': ['No inferred90K terminal state or new execution.', 'No ordering/diversity/SLO/worst-case claim.',
                    'Current sampled counters and process-lifetime peaks remain distinct; no memory hard cap claim.',
                    'Verifier checks saved evidence, not independent reproduction of resource timeout cause.']}, indent=2), encoding='utf-8')
