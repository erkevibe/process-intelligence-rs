"""Independent saved ProcessModel -> unmodified PM4Py BPMN/net semantics."""
import importlib.util
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('s27_model_audit',ROOT/'tools/sprint27/audit-rust-comparison.py');A=importlib.util.module_from_spec(spec);spec.loader.exec_module(A)
spec=importlib.util.spec_from_file_location('s27_model_reference',ROOT/'tools/sprint19/quality-reference.py');B=importlib.util.module_from_spec(spec);spec.loader.exec_module(B)
def graph(model,libraries):
    from pm4py.objects.bpmn.obj import BPMN
    types={'start':BPMN.StartEvent,'end':BPMN.NormalEndEvent,'task':BPMN.Task,'exclusive_gateway':BPMN.ExclusiveGateway,'parallel_gateway':BPMN.ParallelGateway}
    A.need(model['schema_version']==1 and len(model['nodes'])<=128 and len(model['flows'])<=256,'model_subset_bounds')
    bpmn=BPMN(process_id=model['process_id'],name=model['name']);nodes={}
    for row in model['nodes']:
        A.need(row['kind'] in types and row['id'] not in nodes,'supported_unique_node');label=row['label'];A.need(row['kind']!='task' or bool(label),'visible_task_label')
        node=types[row['kind']](id=row['id'],name=label,process=model['process_id']);nodes[row['id']]=node;bpmn.add_node(node)
    seen=set()
    for row in model['flows']:
        A.need(row['id'] not in seen and row['source'] in nodes and row['target'] in nodes,'flow_identity');seen.add(row['id'])
        bpmn.add_flow(BPMN.SequenceFlow(nodes[row['source']],nodes[row['target']],id=row['id'],name=row.get('label',''),process=model['process_id']))
    net,im,fm=libraries['converter'].apply(bpmn,parameters={'use_id':False,'enable_reduction':False})
    structure,places,transitions=B.serialize_net(net,im,fm);raw=B.encoded(structure);state=B.full_graph(net,im,fm,libraries,A.sha(raw));state['states']=[list(row) for row in state['states']]
    state['places']=[places[next(p for p in net.places if str(p.name)==name)] for name in state['places']]
    for row in state['transitions']:row['id']=transitions[next(t for t in net.transitions if str(t.name)==row['id'])]
    for edge in state['edges']:edge['transition']=transitions[next(t for t in net.transitions if str(t.name)==edge['transition'])]
    A.CONSERVATION.validate(raw,state);return structure,raw,state
