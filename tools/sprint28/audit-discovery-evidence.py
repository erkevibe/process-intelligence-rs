#!/usr/bin/env python3
"""Replay the finite synthetic Sprint28 package. No fresh server/browser claim."""
import hashlib
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, 'duplicate JSON key')
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def encoded(value, sort=False):
    return json.dumps(value, ensure_ascii=False, allow_nan=False,
                      sort_keys=sort, separators=(',', ':')).encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def valid_hash(value):
    return type(value) is str and re.fullmatch('[0-9a-fA-F]{64}', value) is not None


def ordered_model(model):
    keys = ('schema_version', 'process_id', 'name', 'nodes', 'flows', 'discovery')
    require(set(model) == set(keys), 'model fields')
    result = {key: model[key] for key in keys}
    result['nodes'] = []
    for node in model['nodes']:
        value = {key: node[key] for key in ('id', 'kind', 'label', 'x', 'y')}
        if 'dimensions' in node:
            value['dimensions'] = {key: node['dimensions'][key] for key in ('width', 'height')}
        require(set(value) == set(node), 'node fields')
        result['nodes'].append(value)
    result['flows'] = []
    for flow in model['flows']:
        value = {key: flow[key] for key in ('id', 'source', 'target', 'waypoints')}
        value['waypoints'] = [dict(x=p['x'], y=p['y']) for p in flow['waypoints']]
        if 'label' in flow:
            value['label'] = flow['label']
        require(set(value) == set(flow), 'flow fields')
        result['flows'].append(value)
    return result


def ordered_tree(tree):
    value = dict(operator=tree['operator'])
    require(tree['operator'] in ('tau', 'task', 'sequence', 'choice', 'parallel', 'repeat'), 'tree operator')
    if 'children' in tree:
        children = tree['children']
        value['children'] = ([ordered_tree(child) for child in children]
                             if isinstance(children, list) else ordered_tree(children)
                             if isinstance(children, dict) else children)
    require(set(value) == set(tree), 'tree fields')
    return value


def metrics(report, traces, events, numerator, denominator):
    require(type(report['trace_count']) is int and report['trace_count'] == traces, 'trace coverage')
    require(type(report['variant_count']) is int and report['variant_count'] == traces, 'variant coverage')
    require(report['profile'] == 'application_bounded_v1', 'profile')
    m = report['metrics']
    require(all(m[key]['status'] == 'measured' for key in ('fitness', 'precision', 'simplicity')), 'measured outcomes')
    f = m['fitness']
    require(type(f['fitness']['log_fitness']) in (int, float) and f['fitness']['log_fitness'] == 1, 'fitness value')
    components = f['integer_components']
    for key, value in dict(traces=traces, events=events, weighted_total_cost=0).items():
        require(type(components[key]) is int and components[key] == value, 'fitness integer components')
    require(components['log_denominator'] == events + traces * components['empty_cost'], 'fitness denominator')
    p = m['precision']
    for key, value in dict(numerator=numerator, denominator=denominator, activated_weight=denominator, escaping_weight=denominator-numerator).items():
        require(type(p[key]) is int and p[key] == value, 'precision integer components')
    require(type(p['scalar']) in (int, float) and p['scalar'] == numerator/denominator, 'precision scalar')
    s = m['simplicity']
    require(type(s['numerator']) is int and s['numerator'] == 1 and type(s['denominator']) is int and s['denominator'] == 1, 'simplicity components')
    require(type(s['scalar']) in (int, float) and s['scalar'] == 1, 'simplicity scalar')
    expected_fitness = dict(status='measured', costs=dict(log=1,model=1,sync=0,tau=0),
        fitness=dict(average_fitness=1.0,log_fitness=1.0,perfectly_fitting_frac=1.0,total_costs=0),
        integer_components=dict(empty_cost=3,events=events,log_denominator=events+3*traces,traces=traces,weighted_total_cost=0))
    require(encoded(f,True) == encoded(expected_fitness,True), 'full fitness components')
    expected_precision = dict(status='measured',activated_weight=denominator,denominator=denominator,
        escaping_weight=denominator-numerator,numerator=numerator,scalar=numerator/denominator,
        policy='proper_prefix_all_min_tau_stop_states_label_union_fitting_log_v1')
    require(encoded(p,True) == encoded(expected_precision,True), 'full precision components')
    expected_simplicity = dict(arcs=18,denominator=1,k=2,mean_degree_denominator=18,
        mean_degree_numerator=36,metric='inverse_mean_arc_degree',numerator=1,places=9,
        representation='exact_hashed_net_no_reduction',scalar=1.0,status='measured',transitions=9)
    require(encoded(s,True) == encoded(expected_simplicity,True), 'full simplicity components')
    require(report['schema_version'] == 1 and encoded(report['limits'],True) == encoded(dict(arcs=256,equivalence=1000,fitness=1000,markings=1000,nodes=128,prefix=1000,tau=1000),True), 'exact evaluation limits')


def xml_semantics(raw):
    require(b'<!DOCTYPE' not in raw.upper() and b'<!ENTITY' not in raw.upper(), 'XML declarations')
    root = ET.fromstring(raw)
    ns = '{http://www.omg.org/spec/BPMN/20100524/MODEL}'
    di = '{http://www.omg.org/spec/BPMN/20100524/DI}'
    require(root.tag == ns+'definitions' and set(root.attrib) == {'id','targetNamespace'}, 'supported XML root')
    require(len(root) == 2 and {child.tag for child in root} == {ns+'process',di+'BPMNDiagram'}, 'supported XML document children')
    processes = root.findall(ns+'process')
    require(len(processes) == 1, 'one XML process')
    process = processes[0]
    require(set(process.attrib) == {'id','name','isExecutable'}, 'supported XML process attributes')
    require(process.get('isExecutable') == 'false', 'non-executable XML')
    kinds = dict(startEvent='start',endEvent='end',task='task',exclusiveGateway='exclusive_gateway',parallelGateway='parallel_gateway')
    nodes, flows = [], []
    for child in process:
        local = child.tag.removeprefix(ns)
        require(len(child) == 0 and not (child.text or '').strip(), 'XML child elements')
        if child.tag == ns+'sequenceFlow':
            require(set(child.attrib) <= {'id','sourceRef','targetRef','name'} and {'id','sourceRef','targetRef'} <= set(child.attrib), 'supported XML attributes')
            flows.append((child.get('id'),child.get('sourceRef'),child.get('targetRef'),child.get('name','')))
        else:
            require(child.tag.startswith(ns) and local in kinds, 'supported XML element')
            require(set(child.attrib) <= {'id','name'} and 'id' in child.attrib, 'supported XML attributes')
            nodes.append((child.get('id'),kinds[local],child.get('name','')))
    require(len(nodes) == len({n[0] for n in nodes}) and len(flows) == len({f[0] for f in flows}), 'unique XML identities')
    return process.get('id'),process.get('name',''),sorted(nodes),sorted(flows)


def model_semantics(model):
    return model['process_id'],model['name'],sorted((n['id'],n['kind'],n['label']) for n in model['nodes']),sorted((f['id'],f['source'],f['target'],f.get('label','')) for f in model['flows'])


def training_export(root):
    d = decode((Path(root)/'discovery-report.json').read_bytes())
    method = decode((Path(root)/'build-proof.json').read_bytes())['quality_method_compatibility']
    m, artifact = d['metadata'], d['artifact']
    o = artifact['output']
    evaluation = dict(schema_version=1,saved_history=True,source_project_id=m['source_project_id'],
        model_id=m['model_id'],model_name=m['model_name'],model_revision=1,log_id=m['log_id'],log_name=m['log_name'],
        analysis_version=m['analysis_version'],source_sha256=m['source_sha256'],on_construction_log=True,
        training_relation='training_snapshot',method_sha256=method,input_model_sha256=o['model_sha256'],
        input_variants_sha256=m['variants_sha256'],created_at=m['created_at'],report=o['training_report'])
    return dict(schema_version=1,method_sha256=method,evaluation=evaluation,input=dict(model=o['model'],variants=artifact['input']['variants']))


def audit(root):
    root = Path(root).resolve(strict=True)
    require(root.is_dir(), 'package directory')
    manifest = decode((root/'manifest.json').read_bytes())
    require(manifest['schema_version'] == 1 and 1 <= len(manifest['files']) <= 64, 'manifest schema')
    inventory = {}
    total = 0
    for entry in manifest['files']:
        name = entry['path']
        require(type(name) is str and re.fullmatch(r'[a-z0-9][a-z0-9._-]*', name) and name != 'manifest.json', 'manifest path')
        require(name not in inventory, 'duplicate manifest path')
        path = root/name
        require(path.is_file() and not path.is_symlink(), 'regular package file')
        raw = path.read_bytes()
        require(type(entry['bytes']) is int and entry['bytes'] == len(raw) <= 2*1024*1024, 'file byte bound')
        require(sha(raw) == entry['sha256'], 'file hash')
        total += len(raw)
        inventory[name] = raw
    require(total <= 16*1024*1024, 'package byte bound')
    require({p.name for p in root.iterdir()} == set(inventory) | {'manifest.json'}, 'unlisted package content')
    def load(name):
        return decode(inventory[name])
    for name, raw in inventory.items():
        if name.endswith('.jpg'):
            require(raw.startswith(b'\xff\xd8\xff') and raw.endswith(b'\xff\xd9'), 'JPEG signature')
        else:
            value = raw.decode('utf-8-sig')
            require(re.search(r'(?i)[a-z]:[\\/]+Users[\\/]|postgresql://|password|database_url|cookie', value) is None, 'private material')
    native = load('native-proof.json')
    build = load('build-proof.json')
    require(native['status'] == 'S28_DISCOVERY_CORE_HTTP_COMPLETE_PENDING_INDEPENDENT', 'closed native proof')
    require(build['status'] == 'DIRECT_OWNED_CARGO_COMMANDS_CLOSED', 'closed build proof')
    for proof in (native, build):
        for side in ('before', 'after'):
            observed = proof[side]
            for key in ('root_logical_bytes', 'root_allocation_bytes'):
                require(type(observed[key]) is int and 0 <= observed[key] <= 10*1024**3-512*1024**2, 'root resource observation')
            for key in ('logical_bytes', 'allocation_bytes'):
                require(type(observed[key]) is int and 0 <= observed[key] <= 14*1024**3-512*1024**2, 'total resource observation')
    labels = {'worker','postgres-g1','pg-stop-g1','cluster','create-core','create-migration','test-core','test-migration','verify-old-report','capacity-v5','old-before','old-after','old-binary','app-live','http-basic','ready-01','ready-02'}
    require(set(native['records']) == labels, 'capture coverage')
    for label, record in native['records'].items():
        expected = 1 if label in ('ready-01', 'old-binary') else 137 if label == 'app-live' else 0
        require(type(record['native_exit']) is int and record['native_exit'] == expected, 'native exit')
        require(record['source_status'] == 'captured', 'capture source')
        require(all(record[key] is True for key in ('stdout_complete','stderr_complete','stdout_eof','stderr_eof','retained_native_handle','resumed')), 'complete streams')
        require(all(record[key] is False for key in ('stdout_fault','stderr_fault','stdout_truncated','stderr_truncated','drain_timeout')), 'stream fault')
        require(valid_hash(record['stdout_sha256']) and valid_hash(record['stderr_sha256']), 'capture hashes')
    require(valid_hash(native['old_before_sha256']) and native['old_before_sha256'] == native['old_after_sha256'], 'old binary no-write snapshot')
    require(native['source_commit'] == build['source_commit'], 'source commit binding')
    require(len(build['commands']) == 4 and len(build['pins']) == 92, 'build coverage')
    for command in build['commands']:
        require(command['native_exit'] == 0 and command['stdout_complete'] is True and command['stderr_complete'] is True, 'build exit/streams')
        require(all(command[key] is False for key in ('output_limit','drain_timeout','capture_fault')), 'build stream fault')
    require(load('core-proof.json')['status'] == 'S28_PG_DISCOVERY_CORE_PASS', 'PG core outcome')
    require(load('http-proof.json')['status'] == 'S28_DISCOVERY_HTTP_PASS', 'HTTP outcome')
    review = load('independent-review.json')
    require(review['status'] == 'PASS_SPRINT28_FINAL_LOCAL_PRODUCT_AND_EVIDENCE_REVIEW' and review['blockers'] == [], 'independent review')
    require(review['product_head'] == native['source_commit'], 'review head')
    pin_review = load('build-pin-review.json')
    require(pin_review['status'] == 'PASS_SPRINT28_BUILD_PIN_COVERAGE_CLARIFICATION' and pin_review['blockers'] == [], 'build pin review')
    require(pin_review['product_head'] == native['source_commit'] and pin_review['verified']['current_hash_matches'] == 92 and pin_review['verified']['rust_source_pins'] == 90, 'complete build pin review')
    paths = [pin['path'] for pin in build['pins']]
    require(len(set(paths)) == 92 and sum(path.endswith('.rs') for path in paths) == 90 and {'Cargo.toml','Cargo.lock'} <= set(paths), 'unique source pin coverage')
    require(all(not Path(path).is_absolute() and '..' not in Path(path).parts and valid_hash(pin['sha256']) for path,pin in zip(paths,build['pins'])), 'bounded source pins')
    lines = inventory['capacity-v5.txt'].decode().splitlines()
    require(len(lines) == 2 and lines[1] == 'CAPACITY_DIAGNOSTIC_COMMITTED_V1', 'diagnostic commit marker')
    diagnostic = decode(lines[0].encode())
    require(diagnostic['storage_schema_version'] == 5 and diagnostic['transaction_read_only'] == 'on' and diagnostic['transaction_isolation'] == 'repeatable read', 'diagnostic scope')
    require(len(diagnostic['record_counts']) == 8 and diagnostic['record_counts']['discovery'] >= 4, 'diagnostic discovery coverage')
    training = [dict(sequence=['A','B','B','C'],frequency=1),dict(sequence=['A','B','C'],frequency=1)]
    heldout = [dict(sequence=['A','B','B','B','C'],frequency=1)]
    d = load('discovery-report.json')
    meta, artifact = d['metadata'], d['artifact']
    require(meta['snapshot']['state'] == 'completed' and meta['snapshot']['result_id'] == artifact['id'], 'discovery identity')
    require(encoded(artifact['input']['variants'], True) == encoded(training, True), 'exact training input')
    require(sha(encoded(training, True)) == meta['variants_sha256'], 'training input hash')
    output = artifact['output']
    model = ordered_model(output['model'])
    require(sha(encoded(model)) == output['model_sha256'], 'discovery model hash')
    ordered = dict(model=model,tree=ordered_tree(output['tree']),exact_variant_fallbacks=output['exact_variant_fallbacks'],model_sha256=output['model_sha256'],training_report=decode(encoded(output['training_report'],True)))
    require(sha(encoded(ordered)) == meta['output_sha256'], 'discovery output hash')
    require(output['training_report']['model_sha256'] == output['model_sha256'] and output['training_report']['variants_sha256'] == meta['variants_sha256'], 'training report binding')
    metrics(output['training_report'], 2, 7, 9, 10)
    exports = [load(name) for name in ('browser-original-report.json','browser-imported-report.json')]
    browser = load('browser-proof.json')
    require(browser['status'] == 'S28_ACTUAL_BROWSER_PASS', 'browser outcome')
    expected_browser = dict(discovery_job='job-30',model='model-32',control_quality_job='job-33',imported_model='model-35',imported_quality_job='job-36',control_log='log-29',training_log='log-19')
    require(all(browser[key] == value for key,value in expected_browser.items()), 'browser proof identities')
    require(browser['screenshots'] == ['browser-control.jpg','browser-roundtrip.jpg'], 'browser screenshot binding')
    for exported, model_id, relation in zip(exports, ('model-32','model-35'), ('different_log_unverified','training_unknown')):
        value, source = exported['evaluation'], exported['input']
        require(value['model_id'] == model_id and value['log_id'] == 'log-29' and value['training_relation'] == relation, 'browser report identity')
        require(encoded(source['variants'], True) == encoded(heldout,True), 'exact heldout input')
        require(exported['method_sha256'] == build['quality_method_compatibility'] == value['method_sha256'], 'quality method binding')
        require(sha(encoded(ordered_model(source['model']))) == value['input_model_sha256'] == value['report']['model_sha256'], 'browser model hash')
        require(sha(encoded(heldout,True)) == value['input_variants_sha256'] == value['report']['variants_sha256'], 'browser variants hash')
        metrics(value['report'], 1, 5, 5, 8)
    require(encoded(exports[0]['evaluation']['report']['metrics'],True) == encoded(exports[1]['evaluation']['report']['metrics'],True), 'full browser roundtrip metrics')
    require(xml_semantics(inventory['browser-model.bpmn']) == model_semantics(exports[0]['input']['model']) == model_semantics(exports[1]['input']['model']), 'browser BPMN semantic binding')
    return dict(status='S28_PUBLIC_DISCOVERY_EVIDENCE_PASS', files=len(inventory), bytes=total,
                exact_training_variants=2, browser_control_precision='5/8',
                full_roundtrip_metrics_identical=True, fresh_execution_claimed=False)


if __name__ == '__main__':
    try:
        require(len(sys.argv) in (2,4), 'package path and optional training export path required')
        print(json.dumps(audit(sys.argv[1]), sort_keys=True))
        if len(sys.argv) == 4:
            require(sys.argv[2] == '--emit-training-export', 'training export option')
            destination = Path(sys.argv[3]).resolve()
            require(not destination.is_relative_to(Path(sys.argv[1]).resolve()), 'derived export outside immutable package')
            with destination.open('xb') as stream:
                stream.write(encoded(training_export(sys.argv[1]),True))
    except Exception as error:
        print(json.dumps(dict(status='FAIL', reason=str(error))), file=sys.stderr)
        raise SystemExit(1)
