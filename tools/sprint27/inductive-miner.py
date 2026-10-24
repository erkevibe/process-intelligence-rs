"""Bounded experiment with actual installed PM4Py IM; training XES only.

Run through the native supervisor. This is not a Rust implementation or server
dependency. No control JSON is accepted by this command.
"""
import argparse, importlib.util, json, time, xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
A=module('s27_audit',ROOT/'tools/sprint27/audit-rust-comparison.py')
B=module('s19_reference',ROOT/'tools/sprint19/quality-reference.py')
def encoded(value):return (json.dumps(value,sort_keys=True,ensure_ascii=False,allow_nan=False,separators=(',',':'))+'\n').encode()
def save(path,value):
    with path.open('xb') as stream:stream.write(encoded(value))
def project(bpmn):
    from pm4py.objects.bpmn.obj import BPMN
    kinds={BPMN.Task:'task',BPMN.StartEvent:'start',BPMN.NormalStartEvent:'start',BPMN.EndEvent:'end',BPMN.NormalEndEvent:'end',BPMN.ExclusiveGateway:'exclusive_gateway',BPMN.ParallelGateway:'parallel_gateway'}
    nodes={};edges=[]
    for node in bpmn.get_nodes():
        A.need(type(node) in kinds,'unsupported_bpmn_node:'+type(node).__name__)
        identity=str(node.get_id());A.need(identity not in nodes,'unique_node_identity')
        kind=kinds[type(node)];label=node.get_name() or '';A.need(isinstance(label,str) and len(label.encode())<=200,'node_label')
        A.need(kind!='task' or bool(label),'empty_task_is_not_silently_invisible')
        nodes[identity]=(kind,label)
    seen=set()
    for flow in bpmn.get_flows():
        A.need(type(flow) is BPMN.SequenceFlow,'unsupported_bpmn_flow')
        identity=str(flow.get_id());a=str(flow.get_source().get_id());b=str(flow.get_target().get_id());label=flow.get_name() or ''
        A.need(identity not in seen and a in nodes and b in nodes,'flow_identity');seen.add(identity);edges.append((a,b,label,identity))
    base={identity:json.dumps(value,ensure_ascii=False) for identity,value in nodes.items()}
    def rank(signatures):
        order={v:i for i,v in enumerate(sorted(set(signatures.values())))}
        return {identity:order[value] for identity,value in signatures.items()}
    colors=rank(base)
    for _ in nodes:
        signatures={identity:json.dumps([base[identity],colors[identity],sorted((colors[a],label) for a,b,label,_ in edges if b==identity),sorted((colors[b],label) for a,b,label,_ in edges if a==identity)],ensure_ascii=False) for identity in nodes}
        updated=rank(signatures)
        if updated==colors:break
        colors=updated
    A.need(len(set(colors.values()))==len(nodes),'ambiguous_canonical_symmetry')
    ids={identity:'n'+str(color) for identity,color in colors.items()};model={'schema_version':1,'process_id':'inductive_experiment','name':'PM4Py Inductive Miner IM','nodes':[],'flows':[],'discovery':None}
    for index,identity in enumerate(sorted(nodes,key=lambda i:colors[i])):
        kind,label=nodes[identity];model['nodes'].append({'id':ids[identity],'kind':kind,'label':label,'x':100.+index%8*170.,'y':100.+index//8*130.})
    flow_ids={}
    for index,(a,b,label,identity) in enumerate(sorted(edges,key=lambda e:(ids[e[0]],ids[e[1]],e[2],e[3]))):
        name='f'+str(index);flow_ids[identity]=name;model['flows'].append({'id':name,'source':ids[a],'target':ids[b],'label':label,'waypoints':[]})
    A.need(sum(n['kind']=='start' for n in model['nodes'])==sum(n['kind']=='end' for n in model['nodes'])==1,'one_start_end')
    return model,{'nodes':ids,'flows':flow_ids}
def main():
    p=argparse.ArgumentParser();p.add_argument('training_xes',type=Path);p.add_argument('output',type=Path);args=p.parse_args()
    A.need(args.output.is_dir() and not any(args.output.iterdir()),'empty_output')
    raw=A.read(args.training_xes,1024*1024);root=ET.fromstring(raw);variants=Counter();events=0;labels=set()
    for trace in root.findall('{*}trace'):
        sequence=[]
        for event in trace.findall('{*}event'):
            values=[v.attrib['value'] for v in event.findall('{*}string') if v.attrib.get('key')=='concept:name']
            A.need(len(values)==1 and 0<len(values[0].encode())<=200,'event_name');sequence.append(values[0]);labels.add(values[0])
        A.need(0<len(sequence)<=64,'training_trace_length');events+=len(sequence);variants[tuple(sequence)]+=1
    A.need(sum(variants.values())<=64 and events<=500 and len(variants)<=32 and len(labels)<=6,'training_bounds')
    result={'schema_version':1,'algorithm':'pm4py-inductive-im','library':'pm4py@2.7.17','variant':'IM','parameters':{},'training_xes_sha256':A.sha(raw),'input_traces':sum(variants.values()),'input_events':events,'control_input_accepted':False}
    if not variants:result['status']='no_data';save(args.output/'result.json',result);return
    libraries=B.api()
    from pm4py.algo.discovery.inductive import algorithm as im
    from pm4py.objects.conversion.process_tree import converter as pt
    from pm4py.objects.conversion.process_tree.variants import to_bpmn
    from pm4py.objects.bpmn.exporter import exporter
    log=libraries['EventLog']()
    for sequence,count in sorted(variants.items()):
        for _ in range(count):log.append(libraries['Trace']([libraries['Event']({'concept:name':label}) for label in sequence]))
    started=time.perf_counter_ns();tree=im.apply(log,variant=im.Variants.IM,parameters={});result['mining_nanos']=time.perf_counter_ns()-started
    (args.output/'tree.txt').write_text(str(tree)+'\n',encoding='utf-8')
    net,initial,final=pt.apply(tree);structure,places,transitions=B.serialize_net(net,initial,final);data=encoded(structure)
    graph=B.full_graph(net,initial,final,libraries,A.sha(data));graph['places']=[places[next(p for p in net.places if str(p.name)==name)] for name in graph['places']]
    for row in graph['transitions']:row['id']=transitions[next(t for t in net.transitions if str(t.name)==row['id'])]
    for edge in graph['edges']:edge['transition']=transitions[next(t for t in net.transitions if str(t.name)==edge['transition'])]
    A.CONSERVATION.validate(data,graph);save(args.output/'original-net.json',structure);save(args.output/'original-graph.json',graph)
    bpmn=to_bpmn.apply(tree);exporter.apply(bpmn,str(args.output/'original.bpmn'))
    try:model,mapping=project(bpmn)
    except ValueError as error:result.update(status='projection_refused',reason=str(error))
    else:
        save(args.output/'model.json',model);save(args.output/'projection.json',mapping);result.update(status='model_projected',model_input_sha256=A.sha(A.read(args.output/'model.json')))
    result['original_bpmn_sha256']=A.sha(A.read(args.output/'original.bpmn'));result['source_pins']=libraries['pins'];save(args.output/'result.json',result)
    print(json.dumps({'status':result['status'],'traces':result['input_traces']}))
if __name__=='__main__':main()
