"""Check own finite graph observation against actual upstream BPMN export.

Structural serialization evidence only, not BPMN XSD validity, replay fitness,
precision, soundness, or algorithm equivalence.
"""
import argparse
import hashlib
import json
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--reference', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
reference = json.loads(args.reference.read_text(encoding='utf-8-sig'))
namespace = '{http://www.omg.org/spec/BPMN/20100524/MODEL}'
types = {'Activity': 'task', 'Gateway': None, 'Event': None}
gateways = {'DATABASED': 'exclusiveGateway', 'PARALLEL': 'parallelGateway',
            'INCLUSIVE': 'inclusiveGateway', 'EVENTBASED': 'eventBasedGateway'}
events = {'START': 'startEvent', 'END': 'endEvent', 'INTERMEDIATE': 'intermediateCatchEvent'}
rows = []
for case in reference['cases']:
    observed = case['observation']
    captures = Path(case['native']['path'])
    stdout = (captures / 'child.stdout').read_text(encoding='utf-8-sig', errors='strict')
    stderr = (captures / 'child.stderr').read_text(encoding='utf-8-sig', errors='strict')
    row = {'id': case['id'], 'actual_status': observed['status'],
           'safe_dfg_retry_message': 'trying a second time' in stdout,
           'bare_dfg_return_message': 'returning the bare DFGP' in stdout,
           'stdout_error_lines': [line for line in stdout.splitlines() if 'ERROR' in line],
           'stderr_non_environment_lines': [line for line in stderr.splitlines()
                if line and 'Picked up ' not in line],
           'checks': dict(case['input_manual_checks'])}
    # Preserve every upstream warning/error. Successful return is independent
    # from algorithm-internal warning logs or graph quality.
    if 'graph' in observed:
        path = args.reference.parent / (case['id'] + '.bpmn')
        data = path.read_bytes()
        root = ET.fromstring(data)
        process = root.find(namespace + 'process')
        assert process is not None, 'exported process missing'
        elements = {element.attrib['id']: element for element in process if 'id' in element.attrib}
        graph = observed['graph']
        nodes = {node['id']: node for node in graph['nodes']}
        flows = {flow['id']: flow for flow in graph['flows']}
        checks = row['checks']
        checks['unique_node_ids'] = len(nodes) == len(graph['nodes'])
        checks['unique_flow_ids'] = len(flows) == len(graph['flows'])
        checks['export_sha256'] = hashlib.sha256(data).hexdigest() == observed['bpmn_sha256']
        checks['flow_endpoints'] = all(f['source'] in nodes and f['target'] in nodes for f in flows.values())
        checks['export_node_labels'] = all(nid in elements and elements[nid].attrib.get('name', '') == node['label'] for nid, node in nodes.items())
        def node_type(node):
            kind = node['class'].split('.')[-1]
            if kind == 'Gateway':
                return gateways[node['gateway_type']]
            if kind == 'Event':
                return events[node['event_type']]
            return types[kind]
        checks['export_node_types'] = all(elements[nid].tag == namespace + node_type(node) for nid, node in nodes.items())
        checks['export_flows'] = all(fid in elements and elements[fid].tag == namespace + 'sequenceFlow'
            and elements[fid].attrib['sourceRef'] == flow['source']
            and elements[fid].attrib['targetRef'] == flow['target'] for fid, flow in flows.items())
        checks['exact_export_graph_ids'] = set(elements) == set(nodes) | set(flows)
        row['activities'] = sorted(node['label'] for node in nodes.values() if node['class'].endswith('.Activity'))
        row['gateway_types'] = sorted(node['gateway_type'] for node in nodes.values() if 'gateway_type' in node)
        row['nodes'] = len(nodes)
        row['flows'] = len(flows)
    rows.append(row)
result = {'schema_version': 1, 'status': 'FINITE_GRAPH_EXPORT_CHECKS_OBSERVED',
          'reference_sha256': hashlib.sha256(args.reference.read_bytes()).hexdigest(),
          'checker_source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'all_structural_checks': all(all(row['checks'].values()) for row in rows),
          'cases': rows,
          'limitations': ['No XSD/DI/layout/reimport claim', 'No token replay or fitness/precision/soundness claim',
                          'Not Rust miner parity; exact named upstream parameter tuple only']}
with args.out.open('x', encoding='utf-8') as output:
    json.dump(result, output, indent=2)
    output.write('\n')
print(json.dumps({'status': result['status'], 'all_structural_checks': result['all_structural_checks'],
                  'sha256': hashlib.sha256(args.out.read_bytes()).hexdigest()}))
