"""Real PM4Py IM: training lineage, original PN/XML language and Rust metrics."""
import argparse,importlib.util,json,xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
A=module('s27_audit',ROOT/'tools/sprint27/audit-rust-comparison.py')
J=module('s27_java_audit',ROOT/'tools/sprint27/audit-java-comparison.py')
I=module('s27_inductive',ROOT/'tools/sprint27/inductive-miner.py')
R=J.R
F=module('s27_frozen',ROOT/'tools/sprint27/frozen-inputs.py')
L=module('s27_model',ROOT/'tools/sprint27/model-language.py')
def main():
    p=argparse.ArgumentParser();p.add_argument('run',type=Path);p.add_argument('scores',type=Path);p.add_argument('inputs_base',type=Path);p.add_argument('output',type=Path);args=p.parse_args()
    A.need(args.output.is_dir() and not any(args.output.iterdir()),'new_empty_output')
    proof,config=A.native(args.run,28);projected=[c for c in config['commands'] if A.load(Path(c['arguments'][-1])/'result.json')['status']=='model_projected']
    scored,score_config=A.native(args.scores,len(projected));A.need({c['label'] for c in projected}=={c['label'] for c in score_config['commands']},'exact_projected_score_coverage')
    expected={}
    for name,directory,sha in [('original','inputs01',A.CORPUS),('validation','inputs02','891b1f4306850ac0abd02a2afaeafa61a892847fbf2e73a44b02bdc06bbafa17')]:
        manifest=F.validate(args.inputs_base,name);A.need(manifest['corpus_sha256']==sha,'frozen_corpus')
        for rep in (1,2):
            for case in manifest['cases']:expected['im-'+name+'-r'+str(rep)+'-'+case['id'].replace('_','-')]=(name,rep,directory,case)
    A.need(set(expected)=={c['label'] for c in config['commands']},'complete_im_matrix')
    libraries=R.B.api();rows=[];groups=[];repeats={};expected_groups=set();caps={'reachable_markings':1000,'fitness_search_states':1000,'prefix_search_states':1000,'tau_closure_markings':1000}
    for command in config['commands']:
        label=command['label'];name,rep,input_dir,case=expected[label];directory=args.run/label;source=A.load(directory/'result.json');input_path=args.inputs_base/input_dir/case['input_file'];frozen=A.load(input_path);xes_path=args.inputs_base/input_dir/case['xes_file'];xes=A.read(xes_path)
        A.need(source['algorithm']=='pm4py-inductive-im' and source['library']=='pm4py@2.7.17' and source['variant']=='IM' and source['parameters']=={} and source['control_input_accepted'] is False,'exact_im_profile')
        A.need(source['training_xes_sha256']==case['xes_sha256']==A.sha(xes) and command['arguments'][-2:]==[str(xes_path),str(directory)],'exact_training_xes')
        traces=[]
        for trace in ET.fromstring(xes).findall('{*}trace'):traces.append(tuple(next(v.attrib['value'] for v in e.findall('{*}string') if v.attrib['key']=='concept:name') for e in trace.findall('{*}event')))
        wanted=Counter()
        for v in frozen['train']:wanted[tuple(v['trace'])]+=v['count']
        A.need(Counter(traces)==wanted and [source['input_traces'],source['input_events']]==case['counts']['train'],'training_only_exact_rows')
        row={'label':label,'corpus':name,'case':case['id'],'repetition':rep,'status':source['status']}
        repeats[(name,case['id'],rep)]={'status':source['status'],'reason':source.get('reason')}
        if not frozen['train']:A.need(source['status']=='no_data','empty_no_data');rows.append(row);continue
        original_raw=A.read(directory/'original-net.json');original_graph=A.load(directory/'original-graph.json');A.CONSERVATION.validate(original_raw,original_graph)
        original_xml=directory/'original.bpmn';A.need(A.sha(A.read(original_xml))==source['original_bpmn_sha256'],'original_xml_hash')
        xml_net,xml_raw,xml_graph=J.original_graph(original_xml,libraries)
        A.need(A.EQUIVALENCE.compare(original_graph,xml_graph,1000)['status']=='equivalent','original_process_tree_petri_to_bpmn_language_changed')
        if source['status']=='projection_refused':
            try:I.project(libraries['importer'].apply(str(original_xml)))
            except ValueError as error:A.need(str(error)==source['reason'],'explicit_same_refusal')
            else:raise ValueError('unjustified_projection_refusal')
            row['reason']=source['reason'];rows.append(row);continue
        A.need(source['status']=='model_projected','honest_projection_status')
        model,mapping=I.project(libraries['importer'].apply(str(original_xml)))
        A.need(model==A.load(directory/'model.json') and mapping==A.load(directory/'projection.json'),'original_xml_projection_bijection')
        output=args.scores/label;result=A.load(output/'result.json')
        A.need(result['algorithm']=='pm4py-inductive-im' and result['case']==case['id'] and result['input_sha256']==case['input_sha256']==A.sha(A.read(input_path)) and result['projected_model_input_sha256']==source['model_input_sha256']==A.sha(A.read(directory/'model.json')),'exact_score_binding')
        A.need(J.normalized(A.load(output/'model.json'))==J.normalized(model),'projection_fields_preserved')
        row['status']=result['status']
        repeats[(name,case['id'],rep)]={'status':result['status'],'reason':result.get('issue')}
        if result['status']!='modelled':A.need(result['status']=='not_admitted','honest_score_refusal');row['issue']=result['issue'];rows.append(row);continue
        required=R.required_groups(result,frozen);expected_groups.update((label,group) for group in required)
        raw=A.read(output/'bpmn-net.json');net=A.load(output/'bpmn-net.json');graph=A.load(output/'bpmn-graph.json');A.CONSERVATION.validate(raw,graph)
        language=A.EQUIVALENCE.compare(xml_graph,graph,1000);A.need(language['status']=='equivalent','original_im_xml_projection_language_changed')
        exported_net,exported_raw,exported_graph=J.original_graph(output/'model.bpmn',libraries)
        reimported_net,reimported_raw,reimported_graph=L.graph(A.load(output/'reimported-model.json'),libraries)
        A.need(A.EQUIVALENCE.compare(graph,exported_graph,1000)['status']=='equivalent' and A.EQUIVALENCE.compare(graph,reimported_graph,1000)['status']=='equivalent','actual_export_and_reimport_languages_changed')
        A.need(result['model_sha256']==A.sha(A.read(output/'model.json')) and result['held_out_supplied_to_miner'] is False and result['export_reimport_status_identical'] is True and result['export_reimport_metrics_identical'] is True,'exact_roundtrip')
        row.update(model_sha256=result['model_sha256'],soundness=A.soundness(net,graph),original_xml_language_equivalence=language)
        J.save(args.output/(label+'-xml-net.json'),xml_net);J.save(args.output/(label+'-xml-graph.json'),xml_graph)
        for group,file,key in [('training','train.json','train'),('held_out','held-out.json','held_out'),('diagnostic_only','diagnostic-only.json','diagnostic_only')]:
            data=A.load(output/file);A.need(data==[{'sequence':v['trace'],'frequency':v['count']} for v in frozen[key]],'exact_evaluation_rows')
            if group not in required:continue
            A.need(result[group]['status']=='evaluated','measured_group');report=result[group]['report'];A.need(report['model_sha256']==result['model_sha256'] and report['net_sha256']==A.sha(raw),'exact_report_binding')
            reference=R.B.evaluate(net,data,libraries,A.sha(raw),caps);checked=R.compare(report,reference,data);filename=label+'-'+group+'-reference.json';J.save(args.output/filename,reference)
            groups.append({'label':label,'corpus':name,'case':case['id'],'group':group,'comparison':checked,'reference_file':filename,'reference_sha256':A.sha(A.read(args.output/filename))})
        repeats[(name,case['id'],rep)]=result;rows.append(row)
    for name,case,rep in repeats:
        if rep!=1:continue
        left=repeats[(name,case,1)];right=repeats[(name,case,2)];A.need(left['status']==right['status'],'repeat_status')
        if left['status']!='modelled':A.need(left.get('reason')==right.get('reason'),'repeat_refusal_reason');continue
        A.need(left['model_sha256']==right['model_sha256'],'canonical_repeat')
        for group in ('training','held_out','diagnostic_only'):A.need(left.get(group)==right.get(group),'repeat_metrics')
    A.need(len(groups)>0 and len(groups)==len(expected_groups) and {(r['label'],r['group']) for r in groups}==expected_groups,'complete_numeric_group_coverage')
    J.save(args.output/'proof.json',{'schema_version':1,'status':'S27_ACTUAL_IM_ORIGINAL_PN_XML_PROJECTION_AND_PM4PY_METRICS_AUDITED','native_mining_proof_sha256':A.sha(A.read(args.run/'proof.json')),'native_scoring_proof_sha256':A.sha(A.read(args.scores/'proof.json')),'rows':rows,'groups':groups,'pm4py_version':'2.7.17','source_pins':libraries['pins'],'scope':'Exact saved inputs/nets; actual Python IM, not Rust Inductive Miner. No arbitrary-output soundness guarantee.'})
    print(json.dumps({'status':'S27_ACTUAL_IM_AUDITED','rows':len(rows),'groups':len(groups)}))
if __name__=='__main__':main()
