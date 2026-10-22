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
rows = audit.loads(audit.read(evidence / 'downloads.json', 65536))
audit.need(len(rows) == 19, 'exact actual browser download inventory')
total = 0
restart = 0
for meta in rows:
    audit.need(re.fullmatch(r'[a-z0-9.-]+', meta['file']) is not None, 'safe browser filename')
    audit.need(meta['part'] in ('payload', 'report') and re.fullmatch(r'job-[0-9]+', meta['job']), 'browser job identity')
    audit.need(meta['route'] == '/conversions/jobs/' + meta['job'] + '/' + meta['part'], 'browser route binding')
    raw = audit.read(evidence / meta['file'], 25 * 1024 * 1024)
    total += len(raw)
    audit.need(total <= 128 * 1024 * 1024 and meta['bytes'] == len(raw) and meta['sha256'].lower() == audit.digest(raw), 'actual browser download bytes/hash')
    key = (meta['job'], meta['part'])
    if key in records:
        audit.need(meta.get('stage') == 'after_actual_process_restart' and records[key] == raw, 'actual restart download byte identity')
        restart += 1
    records[key] = raw
audit.need(restart == 8, 'all four browser pairs downloaded again after restart')
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
source = audit.read(fixtures / 'rich.xes')
expected_case = next(case for case in corpus['cases'] if case['id'] == 'X06')
manual = expected_case['expected']['manual_semantics']
source_core, losses = audit.core(source, 'xes')
refused = audit.loads(records[('job-9', 'report')])
allowed = audit.loads(records[('job-11', 'report')])
payload = records[('job-11', 'payload')]
for report, policy in ((refused, False), (allowed, True)):
    audit.need(report['schema_version'] == 1 and report['method_sha256'].lower() == audit.METHOD_SHA256
               and report['from'] == 'xes' and report['to'] == 'csv'
               and report['input_sha256'] == audit.digest(source) and report['input_bytes'] == len(source)
               and report['allow_metadata_loss'] is policy, 'rich input/method/policy binding')
audit.need(refused['status'] == 'loss_refused' and ('job-9', 'payload') not in records
           and all(refused.get(k) is None for k in ('target_sha256', 'target_bytes', 'payload_file')), 'refusal has no published target')
audit.need(audit.canonical_losses(refused['details']['losses']) == audit.canonical_losses(losses), 'full refusal loss inventory')
audit.loss_locations(refused['details']['losses'], source, 'xes')
audit.need(allowed['status'] == 'converted' and allowed['target_sha256'] == audit.digest(payload)
           and allowed['target_bytes'] == len(payload), 'allowed target binding')
target_core, target_losses = audit.core(payload, 'csv', strict_output=True)
audit.need(source_core == target_core == audit.loads(audit.read(fixtures / manual['core_file'])) and not target_losses, 'rich manual core')
audit.need(payload == audit.read(fixtures / expected_case['expected']['direct_target_file']), 'rich exact manual CSV')
audit.need(audit.canonical_losses(allowed['evidence']['losses']) == audit.canonical_losses(losses)
           and allowed['evidence']['metadata_loss_count'] == len(losses) == manual['metadata_loss_count'], 'allowed full loss inventory')
audit.log_report_integrity(allowed['evidence'], source, 'xes', payload, 'csv', manual)
audit.need(not output.exists(), 'fresh output required')
output.write_text(json.dumps({'status': 'INDEPENDENT_ACTUAL_BROWSER_DOWNLOAD_MANUAL_SEMANTICS_PASS',
                             'directions': 4, 'browser_downloads': 19, 'restart_downloads': 8, 'rich_loss_policy_pairs': 2, 'http_status_or_headers_claimed': False, 'checked_actual_pairs': checked,
                             'source': 'Frozen preimplementation manual core and full weighted graph/marking files',
                             'converter_or_engine_executed': False}, indent=2), encoding='utf-8')
