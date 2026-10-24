"""Independent lineage, exact graph conservation, original XML language and metrics.

No mining occurs here. Original SplitMiner XML is converted by unmodified PM4Py;
the projected model is scored by the existing Rust facade in a separate process.
"""
import argparse, importlib.util, json, xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
A=module('s27_audit',ROOT/'tools/sprint27/audit-rust-comparison.py')
P=module('s27_projection',ROOT/'tools/sprint27/project-java-models.py')
R=module('s27_metric_reference',ROOT/'tools/sprint27/reference-rust-comparison.py')
B=R.B
PARAMETERS={'percentile_frequency_threshold':.4,'parallelisms_threshold':.1,'filter_type':'WTH','parallelisms_first':False,'replace_iors':True,'remove_loop_activities':False,'structuring_time':'NONE','classifier':'org.deckfour.xes.classification.XEventNameClassifier'}
def encoded(value):return (json.dumps(value,sort_keys=True,ensure_ascii=False,indent=2,allow_nan=False)+'\n').encode()
def save(path,value):
    with path.open('xb') as stream:stream.write(encoded(value))
def normalized(value):
    if isinstance(value,list):return [normalized(v) for v in value]
    if isinstance(value,dict):return {k:normalized(v) for k,v in value.items() if not (k in ('label','dimensions') and v in ('',None))}
    return value
def original_graph(path,libraries):
    bpmn=libraries['importer'].apply(str(path))
    net,im,fm=libraries['converter'].apply(bpmn,parameters={'use_id':False,'enable_reduction':False})
    raw,places,transitions=B.serialize_net(net,im,fm);data=encoded(raw)
    graph=B.full_graph(net,im,fm,libraries,A.sha(data))
    graph['places']=[places[next(p for p in net.places if str(p.name)==name)] for name in graph['places']]
    for row in graph['transitions']:row['id']=transitions[next(t for t in net.transitions if str(t.name)==row['id'])]
    for edge in graph['edges']:edge['transition']=transitions[next(t for t in net.transitions if str(t.name)==edge['transition'])]
    A.CONSERVATION.validate(data,graph)
    return raw,data,graph
def main():
    p=argparse.ArgumentParser();p.add_argument('java',type=Path);p.add_argument('inputs',type=Path);p.add_argument('projection',type=Path);p.add_argument('scores',type=Path);p.add_argument('output',type=Path);args=p.parse_args()
    A.need(args.output.is_dir() and not any(args.output.iterdir()),'empty_output')
    native,commands=A.native(args.java,14);scores,score_config=A.native(args.scores,10)
    manifest=A.load(args.inputs/'manifest.json');A.need(manifest['corpus_sha256']==A.CORPUS,'frozen_corpus')
    cases={c['id']:c for c in manifest['cases']};projection=A.load(args.projection/'proof.json')
    A.need(projection['native_proof_sha256']==A.sha(A.read(args.java/'proof.json')),'projection_native_binding')
    projections={r['label']:r for r in projection['cases']};scored={c['label']:c for c in score_config['commands']}
    libraries=B.api();rows=[];groups=[];repeats={}
    caps={'reachable_markings':1000,'fitness_search_states':1000,'prefix_search_states':1000,'tau_closure_markings':1000}
    for command in commands['commands']:
        label=command['label'];source=A.load(args.java/label/'result.json');projected=projections[label];case=cases[projected['case']]
        frozen=A.load(args.inputs/case['input_file']);xes=A.read(args.inputs/case['xes_file'])
        A.need(A.sha(xes)==case['xes_sha256']==source['input_sha256'],'training_xes_hash')
        root=ET.fromstring(xes);traces=[]
        for trace in root.findall('{*}trace'):
            traces.append(tuple(next(v.attrib['value'] for v in event.findall('{*}string') if v.attrib['key']=='concept:name') for event in trace.findall('{*}event')))
        A.need(Counter(traces)==Counter({tuple(v['trace']):v['count'] for v in frozen['train']}),'xes_only_exact_training_variants')
        A.need([source['input_traces'],source['input_events']]==case['counts']['train'] and source['parameters']==PARAMETERS,'actual_input_counts_and_parameters')
        A.need(source['algorithm_class_sha256']=='e8535a6b65b7e758a49e757d635e8797071b8e860bc8d1c6859e592eb1ee21ad','actual_splitminer_class')
        A.need(projected['source_result_sha256']==A.sha(A.read(args.java/label/'result.json')),'source_projection_binding')
        row={'case':case['id'],'label':label,'status':projected['status']}
        if projected['status']!='model_projected':
            A.need(label not in scored,'refused_model_not_scored')
            if projected['status']=='projection_refused':
                try:P.project(source)
                except ValueError as error:A.need(str(error)==projected['reason'],'same_explicit_refusal')
                else:raise ValueError('projection_refusal_unjustified')
                row['reason']=projected['reason']
            else:A.need(source['status']=='algorithm_exception','honest_exception');row['exception']=source['exception']
            rows.append(row);continue
        model,mapping=P.project(source);input_model=A.load(args.projection/label/'model.json')
        A.need(model==input_model and mapping==projected['mapping'],'exact_graph_projection_bijection')
        directory=args.scores/label;result=A.load(directory/'result.json');output_model=A.load(directory/'model.json')
        A.need(normalized(output_model)==normalized(input_model),'projection_no_semantic_fields_lost')
        A.need(result['input_sha256']==case['input_sha256']==A.sha(A.read(args.inputs/case['input_file'])) and result['projected_model_input_sha256']==projected['model_input_sha256']==A.sha(A.read(args.projection/label/'model.json')),'score_exact_inputs')
        A.need(result['held_out_supplied_to_miner'] is False and result['status']=='modelled','honest_scored_status')
        net_raw=A.read(directory/'bpmn-net.json');net=A.load(directory/'bpmn-net.json');graph=A.load(directory/'bpmn-graph.json');A.CONSERVATION.validate(net_raw,graph)
        original=args.java/label/'model.bpmn';A.need(A.sha(A.read(original))==source['bpmn_sha256']==projected['original_bpmn_sha256'],'original_xml_hash')
        original_net,original_raw,original_state=original_graph(original,libraries)
        equivalence=A.EQUIVALENCE.compare(original_state,graph,1000);A.need(equivalence['status']=='equivalent','original_splitminer_xml_language_changed')
        save(args.output/(label+'-original-net.json'),original_net);save(args.output/(label+'-original-graph.json'),original_state)
        row.update(status='modelled',soundness=A.soundness(net,graph),original_xml_language_equivalence=equivalence,model_sha256=result['model_sha256'])
        A.need(result['model_sha256']==A.sha(A.read(directory/'model.json')) and result['export_reimport_status_identical'] is True and result['export_reimport_metrics_identical'] is True,'exact_model_roundtrip')
        for group,file in [('training','train.json'),('held_out','held-out.json'),('diagnostic_only','diagnostic-only.json')]:
            data=A.load(directory/file);key={'training':'train','held_out':'held_out','diagnostic_only':'diagnostic_only'}[group]
            A.need(data==[{'sequence':v['trace'],'frequency':v['count']} for v in frozen[key]],'exact_evaluation_rows')
            if group not in result:continue
            A.need(result[group]['status']=='evaluated','measured_group_required');report=result[group]['report']
            A.need(report['model_sha256']==result['model_sha256'] and report['net_sha256']==A.sha(net_raw),'exact_report_binding')
            reference=B.evaluate(net,data,libraries,A.sha(net_raw),caps);comparison=R.compare(report,reference,data)
            filename=label+'-'+group+'-reference.json';save(args.output/filename,reference)
            groups.append({'label':label,'case':case['id'],'group':group,'comparison':comparison,'reference_file':filename,'reference_sha256':A.sha(A.read(args.output/filename))})
        key=(case['id'],int(label.split('-r')[1].split('-')[0]));repeats[key]=(result,graph);rows.append(row)
    for case in cases:
        if (case,1) not in repeats:continue
        left,lg=repeats[(case,1)];right,rg=repeats[(case,2)]
        A.need(left['model_sha256']==right['model_sha256'],'repeat_canonical_model')
        for group in ('training','held_out','diagnostic_only'):A.need(left.get(group)==right.get(group),'repeat_metrics')
        A.need(A.EQUIVALENCE.compare(lg,rg,1000)['status']=='equivalent','repeat_language')
    A.need(len(rows)==14 and len(repeats)==10 and len(groups)==22,'complete_java_reference_coverage')
    save(args.output/'proof.json',{'schema_version':1,'status':'S27_SPLITMINER_ORIGINAL_XML_PROJECTION_AND_PM4PY_METRICS_AUDITED','native_java_proof_sha256':A.sha(A.read(args.java/'proof.json')),'native_scores_proof_sha256':A.sha(A.read(args.scores/'proof.json')),'rows':rows,'groups':groups,'pm4py_version':'2.7.17','source_pins':libraries['pins'],'scope':'These exact returned diagrams only; no general SplitMiner soundness guarantee, no Rust port, no fallback-absence claim.'})
    print(json.dumps({'status':'S27_SPLITMINER_AUDITED','rows':len(rows),'groups':len(groups)}))
if __name__=='__main__':main()
