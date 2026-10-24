"""Independent saved HTTP payload semantics, using preimplementation manual S20 oracles.
No converter, miner, database connection or native feature is executed.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

workspace, evidence, output = map(Path, sys.argv[1:])
checker = workspace / 'tools/oracle/audit-conversion-evidence.py'
if hashlib.sha256(checker.read_bytes()).hexdigest() != 'c3cf6d5b5b5b0a4067c29175c4857964b81b766a84d1ed5c029ad49ed929ba3a':
    raise ValueError('accepted independent checker identity')
spec = importlib.util.spec_from_file_location('independent_s20', checker)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
corpus_bytes = audit.read(workspace / 'fixtures/conversions/corpus.json')
audit.need(audit.digest(corpus_bytes) == audit.CORPUS_SHA256, 'approved frozen corpus identity')
corpus = audit.loads(corpus_bytes)
audit.need(corpus['method_sha256'].lower() == audit.METHOD_SHA256, 'approved method identity')
fixtures = workspace / 'fixtures/conversions'
for entry in corpus['files']:
    raw = audit.read(audit.local(fixtures, entry['file']))
    audit.need(len(raw) == entry['bytes'] and audit.digest(raw) == entry['sha256'].lower(), 'frozen manual/input file inventory')
required = [('xes', 'csv', 'flat-unicode.xes'), ('csv', 'xes', 'flat-unicode.csv'),
            ('petri-json', 'pnml', 'weighted-cycle.json'), ('pnml', 'petri-json', 'weighted-cycle.pnml')]
records = {}
total = 0
rows = list(evidence.glob('[0-9][0-9][0-9].json'))
audit.need(len(rows) <= 1000, 'bounded HTTP inventory')
for path in rows:
    meta = audit.loads(audit.read(path, 65536))
    raw = audit.read(path.with_suffix('.body'), 25 * 1024 * 1024)
    total += len(raw)
    audit.need(total <= 128 * 1024 * 1024, 'bounded HTTP total')
    audit.need(meta['bytes'] == len(raw) and meta['sha256'].lower() == audit.digest(raw), 'actual saved HTTP body hash')
    match = re.fullmatch(r'/conversions/jobs/(job-[0-9]+)/(?P<part>payload|report)', meta['route'])
    if meta['method'] == 'GET' and meta['status'] == 200 and match:
        key = (match.group(1), match.group('part'))
        if key in records:
            audit.need(records[key] == raw, 'repeated download byte identity')
        records[key] = raw
checked = []
for source_kind, target_kind, filename in required:
    cases = [row for row in corpus['cases'] if row['from'] == source_kind and row['to'] == target_kind
             and row['input'] == filename and row['expected']['status'] == 'converted']
    audit.need(len(cases) == 1, 'unique frozen manual case')
    case = cases[0]
    source = audit.read(workspace / 'fixtures/conversions' / filename)
    candidates = []
    for (job, part), raw in records.items():
        if part != 'report':
            continue
        report = audit.loads(raw)
        if (report['from'], report['to'], report['input_sha256'], report['status']) == (
                source_kind, target_kind, audit.digest(source), 'converted'):
            candidates.append((job, report, raw))
    audit.need(bool(candidates), 'actual complete HTTP payload/report direction missing')
    for job, report, report_raw in candidates:
        audit.need((job, 'payload') in records, 'actual matching HTTP payload missing')
        payload = records[(job, 'payload')]
        audit.need(type(report['schema_version']) is int and report['schema_version'] == 1
                   and report['method_sha256'].lower() == audit.METHOD_SHA256
                   and report['input_bytes'] == len(source) and report['allow_metadata_loss'] is False,
                   'actual HTTP report schema/method/input/policy')
        audit.need(report['target_sha256'] == audit.digest(payload) and report['target_bytes'] == len(payload), 'actual HTTP report target binding')
        manual = case['expected']['manual_semantics']
        evidence_report = report['evidence']
        audit.need(evidence_report['metadata_loss_count'] == 0, 'manual zero metadata loss')
        if source_kind in ('xes', 'csv'):
            expected = audit.loads(audit.read(workspace / 'fixtures/conversions' / manual['core_file']))
            source_core, source_losses = audit.core(source, source_kind)
            target_core, target_losses = audit.core(payload, target_kind, strict_output=True)
            audit.need(source_core == target_core == expected, 'manual source/HTTP target ordered core')
            audit.need(not source_losses and not target_losses and evidence_report['losses'] == [], 'actual zero losses')
            audit.need(evidence_report['source_core'] == source_core and evidence_report['target_core'] == target_core,
                       'claimed HTTP core summaries')
            audit.log_report_integrity(evidence_report, source, source_kind, payload, target_kind, manual)
            if target_kind == 'csv':
                audit.need(payload == audit.read(audit.local(fixtures, case['expected']['direct_target_file'])), 'exact manual CSV target')
        else:
            expected = audit.manual_graph(audit.loads(audit.read(workspace / 'fixtures/conversions' / manual['graph_file'])))
            source_graph = audit.graph(source, source_kind)
            target_graph = audit.graph(payload, target_kind)
            audit.isomorphic(expected, source_graph)
            audit.isomorphic(expected, target_graph)
            audit.need(audit.mapped_equal(source_graph, target_graph, evidence_report['node_bijection']), 'claimed full source/target bijection')
            audit.need(audit.mapped_equal(source_graph, evidence_report['source_graph'], {key: key for key in source_graph['nodes']}), 'claimed source graph')
            audit.need(audit.mapped_equal(target_graph, evidence_report['target_graph'], {key: key for key in target_graph['nodes']}), 'claimed target graph')
            audit.net_report_integrity(evidence_report, source, source_kind, payload)
        checked.append({'job': job, 'case': case['id'], 'from': source_kind, 'to': target_kind,
                        'payload_sha256': audit.digest(payload), 'report_sha256': audit.digest(report_raw)})
audit.need(not output.exists(), 'fresh output required')
output.write_text(json.dumps({'status': 'INDEPENDENT_SAVED_HTTP_FOUR_DIRECTION_MANUAL_SEMANTICS_PASS',
                             'directions': 4, 'checked_actual_pairs': checked,
                             'source': 'Frozen preimplementation manual core and full weighted graph/marking files',
                             'converter_or_engine_executed': False}, indent=2), encoding='utf-8')
