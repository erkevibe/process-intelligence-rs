#!/usr/bin/env python3
"""Coherently rehash finite counterfactual packages; keep every attempt."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys

script = Path(__file__).with_name('audit-discovery-evidence.py')
spec = importlib.util.spec_from_file_location('s28_auditor', script)
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
source = Path(sys.argv[1]).resolve(strict=True)
output = Path(sys.argv[2]).resolve(strict=True)
a.require(output.is_dir() and not any(output.iterdir()), 'new empty test output')
a.require('sprint28' in output.parts and '.local' in output.parts, 'private bounded output')
a.audit(source)


def put(value, path, replacement):
    current = value
    for key in path[:-1]:
        current = current[key]
    current[path[-1]] = replacement


cases = [
 ('coherent_fitness', 'browser-original-report.json', ('evaluation','report','metrics','fitness','fitness','log_fitness'), 0.125, 'fitness value'),
 ('bool_fitness', 'browser-original-report.json', ('evaluation','report','metrics','fitness','fitness','log_fitness'), True, 'fitness value'),
 ('wrong_precision', 'browser-original-report.json', ('evaluation','report','metrics','precision','scalar'), 0.5, 'precision scalar'),
 ('bool_simplicity', 'browser-original-report.json', ('evaluation','report','metrics','simplicity','numerator'), True, 'simplicity components'),
 ('wrong_model_identity', 'browser-original-report.json', ('evaluation','model_id'), 'model-999', 'browser report identity'),
 ('wrong_control_identity', 'browser-original-report.json', ('evaluation','log_id'), 'log-19', 'browser report identity'),
 ('wrong_provenance', 'browser-imported-report.json', ('evaluation','training_relation'), 'training_snapshot', 'browser report identity'),
 ('training_control_swap', 'browser-original-report.json', ('input','variants'), [dict(sequence=['A','B','C'],frequency=1)], 'exact heldout input'),
 ('bool_frequency', 'browser-original-report.json', ('input','variants'), [dict(sequence=['A','B','B','B','C'],frequency=True)], 'exact heldout input'),
 ('changed_training_input', 'discovery-report.json', ('artifact','input','variants'), [], 'exact training input'),
 ('changed_output_hash', 'discovery-report.json', ('metadata','output_sha256'), '0'*64, 'discovery output hash'),
 ('old_binary_wrote', 'native-proof.json', ('old_after_sha256',), '0'*64, 'old binary no-write snapshot'),
 ('incomplete_stream', 'native-proof.json', ('records','test-core','stdout_complete'), False, 'complete streams'),
 ('wrong_review_head', 'independent-review.json', ('product_head',), 'f'*40, 'review head'),
 ('training_average_bool', 'discovery-report.json', ('artifact','output','training_report','metrics','fitness','fitness','average_fitness'), False, 'full fitness components'),
 ('training_total_costs', 'discovery-report.json', ('artifact','output','training_report','metrics','fitness','fitness','total_costs'), 99, 'full fitness components'),
 ('training_cost_bool', 'discovery-report.json', ('artifact','output','training_report','metrics','fitness','costs','model'), True, 'full fitness components'),
 ('simplicity_arcs', 'browser-original-report.json', ('evaluation','report','metrics','simplicity','arcs'), 19, 'full simplicity components'),
 ('simplicity_degree', 'browser-original-report.json', ('evaluation','report','metrics','simplicity','mean_degree_numerator'), 37, 'full simplicity components'),
 ('simplicity_bool_k', 'browser-original-report.json', ('evaluation','report','metrics','simplicity','k'), True, 'full simplicity components'),
 ('limits_bool', 'browser-original-report.json', ('evaluation','report','limits','fitness'), True, 'exact evaluation limits'),
 ('browser_wrong_model', 'browser-proof.json', ('model',), 'unrelated', 'browser proof identities'),
 ('substituted_bpmn', 'browser-model.bpmn', (), None, 'browser BPMN semantic binding'),
 ('conditional_flow', 'browser-model.bpmn', (), None, 'XML child elements'),
 ('terminating_end_event', 'browser-model.bpmn', (), None, 'XML child elements'),
 ('default_gateway', 'browser-model.bpmn', (), None, 'supported XML attributes'),
]
results = []
for name, filename, path, replacement, expected in cases:
    target = output/name
    a.require(not target.exists() and target.parent == output, 'new bounded case')
    shutil.copytree(source, target)
    if filename.endswith('.bpmn'):
        raw = (target/filename).read_bytes()
        if name == 'conditional_flow':
            changed = re.sub(rb'(<bpmn:sequenceFlow\b[^>]*)/>', rb'\1><bpmn:conditionExpression>false</bpmn:conditionExpression></bpmn:sequenceFlow>', raw, count=1)
        elif name == 'terminating_end_event':
            changed = re.sub(rb'(<bpmn:endEvent\b[^>]*)/>', rb'\1><bpmn:terminateEventDefinition/></bpmn:endEvent>', raw, count=1)
        elif name == 'default_gateway':
            changed = raw.replace(b'<bpmn:exclusiveGateway ', b'<bpmn:exclusiveGateway default="f0" ', 1)
        else:
            changed = raw.replace(b'name="B"',b'name="Z"')
        a.require(changed != raw, 'BPMN fixture mutation')
        (target/filename).write_bytes(changed)
    else:
        value = a.decode((target/filename).read_bytes())
        put(value, path, replacement)
        if filename == 'discovery-report.json' and path[:2] == ('artifact','output'):
            o = value['artifact']['output']
            ordered = dict(model=a.ordered_model(o['model']),tree=a.ordered_tree(o['tree']),exact_variant_fallbacks=o['exact_variant_fallbacks'],model_sha256=o['model_sha256'],training_report=a.decode(a.encoded(o['training_report'],True)))
            value['metadata']['output_sha256'] = a.sha(a.encoded(ordered))
        (target/filename).write_bytes(a.encoded(value, True))
    manifest = a.decode((target/'manifest.json').read_bytes())
    for entry in manifest['files']:
        raw = (target/entry['path']).read_bytes()
        entry['bytes'] = len(raw)
        entry['sha256'] = hashlib.sha256(raw).hexdigest()
    (target/'manifest.json').write_bytes(a.encoded(manifest, True))
    try:
        a.audit(target)
    except ValueError as error:
        a.require(expected in str(error), 'unexpected refusal: ' + name + ': ' + str(error))
        results.append(dict(case=name, outcome='refused', reason=str(error), manifest_coherently_rehashed=True))
    else:
        raise AssertionError('false PASS: ' + name)
proof = dict(status='S28_DISCOVERY_AUDITOR_COUNTERFACTUALS_PASS', positive=1, refused=len(results), cases=results)
(output/'proof.json').write_bytes(json.dumps(proof, sort_keys=True, indent=2).encode())
print(json.dumps(dict(status=proof['status'], positive=1, refused=len(results)), sort_keys=True))
