"""Project the actual unchanged SplitMiner graph to the supported model subset.
Preserves a full node/edge bijection. Standard loops and unknown constructs refuse.
Original BPMN is retained and independently compared through PM4Py afterwards.
"""
import argparse,importlib.util,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('s27_audit',ROOT/'tools/sprint27/audit-rust-comparison.py');A=importlib.util.module_from_spec(spec);spec.loader.exec_module(A)
PREFIX='org.apromore.processmining.models.graphbased.directed.bpmn.elements.'
def project(source):
    graph=source['graph'];nodes=graph['nodes'];flows=graph['flows'];A.need(len(nodes)<=128 and len(flows)<=256,'projection_size')
    base={};kinds={}
    for node in nodes:
        identity=node['id'];A.need(isinstance(identity,str) and identity not in base,'source_node_identity')
        label=node['label'] or '';A.need(isinstance(label,str) and len(label.encode())<=4096,'node_label')
        if node['class']==PREFIX+'Activity':
            if node.get('looped') is not False:raise ValueError('unsupported_standard_loop')
            A.need(bool(label),'empty_activity_label');kind='task'
        elif node['class']==PREFIX+'Gateway':
            A.need(node['gateway_type'] in ('DATABASED','PARALLEL'),'unsupported_gateway')
            kind='exclusive_gateway' if node['gateway_type']=='DATABASED' else 'parallel_gateway'
        else:
            A.need(node['class']==PREFIX+'Event' and node['event_trigger']=='NONE','unsupported_event')
            A.need((node['event_type'],node['event_use']) in (('START','CATCH'),('END','THROW')),'unsupported_event_kind')
            kind='start' if node['event_type']=='START' else 'end'
        kinds[identity]=(kind,label);base[identity]=json.dumps([kind,label],ensure_ascii=False,separators=(',',':'))
    edges=[];seen=set()
    for flow in flows:
        A.need(flow['id'] not in seen and flow['source'] in base and flow['target'] in base,'source_edge_identity');seen.add(flow['id'])
        A.need(flow['condition'] in (None,''),'unsupported_flow_condition')
        label=flow['label'] or '';A.need(isinstance(label,str) and len(label.encode())<=4096,'flow_label')
        edges.append((flow['source'],flow['target'],label,flow['id']))
    def ranks(signatures):
        values={text:i for i,text in enumerate(sorted(set(signatures.values())))}
        return {identity:values[text] for identity,text in signatures.items()}
    colors=ranks(base)
    for _ in base:
        signatures={}
        for identity in base:
            ins=sorted((colors[a],label) for a,b,label,_ in edges if b==identity)
            outs=sorted((colors[b],label) for a,b,label,_ in edges if a==identity)
            signatures[identity]=json.dumps([base[identity],colors[identity],ins,outs],ensure_ascii=False,separators=(',',':'))
        updated=ranks(signatures)
        if updated==colors:break
        colors=updated
    A.need(len(set(colors.values()))==len(base),'ambiguous_canonical_node_symmetry')
    ids={identity:'n'+str(color) for identity,color in colors.items()}
    ordered=sorted(base,key=lambda identity:colors[identity])
    model={'schema_version':1,'process_id':'splitminer_experiment','name':graph['label'] or 'SplitMiner experiment','nodes':[],'flows':[],'discovery':None}
    for index,identity in enumerate(ordered):
        kind,label=kinds[identity];model['nodes'].append({'id':ids[identity],'kind':kind,'label':label,'x':100.0+(index%8)*170.0,'y':100.0+(index//8)*130.0})
    flow_ids={}
    for index,(a,b,label,identity) in enumerate(sorted(edges,key=lambda e:(ids[e[0]],ids[e[1]],e[2],e[3]))):
        name='f'+str(index);flow_ids[identity]=name;model['flows'].append({'id':name,'source':ids[a],'target':ids[b],'waypoints':[],'label':label})
    A.need(sum(n['kind']=='start' for n in model['nodes'])==sum(n['kind']=='end' for n in model['nodes'])==1,'single_start_end')
    return model,{'nodes':ids,'flows':flow_ids,'geometry_policy':'New deterministic display geometry; source behavior and all labels/edges retained.'}
def main():
    p=argparse.ArgumentParser();p.add_argument('run',type=Path);p.add_argument('inputs',type=Path);p.add_argument('output',type=Path);args=p.parse_args();A.need(args.output.is_dir() and not any(args.output.iterdir()),'new_empty_output')
    proof,config=A.native(args.run,14);manifest=A.load(args.inputs/'manifest.json');A.need(manifest['corpus_sha256']==A.CORPUS,'frozen_corpus');cases={c['id']:c for c in manifest['cases']};rows=[]
    for command in config['commands']:
        label=command['label'];directory=args.run/label;source=A.load(directory/'result.json');case=next(c for name,c in cases.items() if label.endswith('-'+name.replace('_','-')))
        A.need(source['input_sha256']==case['xes_sha256'] and source['algorithm_class_sha256']=='e8535a6b65b7e758a49e757d635e8797071b8e860bc8d1c6859e592eb1ee21ad','actual_miner_training_identity')
        output=args.output/label;output.mkdir();row={'label':label,'case':case['id'],'source_result_sha256':A.sha(A.read(directory/'result.json')),'input_sha256':case['input_sha256'],'source_status':source['status']}
        if source['status']=='algorithm_exception':row.update(status='algorithm_exception',exception=source['exception'])
        elif source['status']!='diagram_returned':row.update(status='not_selected',reason=source['status'])
        else:
            original=A.read(directory/'model.bpmn');A.need(A.sha(original)==source['bpmn_sha256'],'actual_exported_bpmn')
            row['original_bpmn_sha256']=A.sha(original)
            try:model,mapping=project(source)
            except ValueError as error:row.update(status='projection_refused',reason=str(error))
            else:
                data=(json.dumps(model,ensure_ascii=False,separators=(',',':'),sort_keys=True)+'\n').encode();(output/'model.json').write_bytes(data)
                row.update(status='model_projected',model_input_sha256=A.sha(data),mapping=mapping)
        (output/'projection.json').write_text(json.dumps(row,sort_keys=True,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');rows.append(row)
    summary={'schema_version':1,'status':'S27_ACTUAL_SPLITMINER_GRAPHS_PROJECTED_WITH_EXPLICIT_REFUSALS','native_proof_sha256':A.sha(A.read(args.run/'proof.json')),'cases':rows,'quality_scoring_pending':True,'original_xml_conversion_comparison_pending':True}
    (args.output/'proof.json').write_text(json.dumps(summary,sort_keys=True,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':summary['status'],'projected':sum(r['status']=='model_projected' for r in rows),'total':len(rows)}))
if __name__=='__main__':main()
