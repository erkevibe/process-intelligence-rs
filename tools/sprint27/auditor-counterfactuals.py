"""Positive fixtures and deliberate corruptions of the independent auditors."""
import argparse,copy,importlib.util,json,xml.etree.ElementTree as ET
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
S=module('s27_control_structured',ROOT/'tools/sprint27/audit-structured-comparison.py')
A=S.A;R=S.R;F=S.F;J=S.J;L=S.L
def main():
    p=argparse.ArgumentParser();p.add_argument('base',type=Path);p.add_argument('output',type=Path);args=p.parse_args();A.need(args.output.is_dir() and not any(args.output.iterdir()),'empty_control_output')
    passed=[]
    for name in F.SETS:F.validate(args.base,name);passed.append('positive_frozen_'+name)
    directory=args.base/'rust02/observed-r1-linear';result=A.load(directory/'result.json');report=result['held_out']['report'];rows=A.load(directory/'held-out.json');reference=A.load(args.base/'audits01/reference/observed-r1-linear-held_out.json')
    R.compare(report,reference,rows);passed.append('positive_original_metric_fixture')
    frozen=A.load(args.base/'inputs01/linear.json');R.required_groups(result,frozen)
    missing=copy.deepcopy(result);del missing['held_out']
    try:R.required_groups(missing,frozen)
    except ValueError:passed.append('refused_deleted_required_held_out_group')
    else:raise ValueError('missing_required_group_accepted')
    mutations=[('boolean_fitness',['metrics','fitness','fitness','log_fitness'],True),('boolean_precision',['metrics','precision','scalar'],True),('boolean_zero_cost',['metrics','fitness','integer_components','weighted_total_cost'],False),('boolean_simplicity',['metrics','simplicity','scalar'],True),('wrong_simplicity_status',['metrics','simplicity','status'],'inconclusive'),('wrong_variants_hash',['variants_sha256'],'0'*64),('boolean_variant_count',['variant_count'],True),('wrong_trace_count',['trace_count'],999),('boolean_profile_limit',['limits','nodes'],True)]
    for name,path,value in mutations:
        forged=copy.deepcopy(report);cursor=forged
        for key in path[:-1]:cursor=cursor[key]
        cursor[path[-1]]=value
        try:R.compare(forged,reference,rows)
        except ValueError:passed.append('refused_'+name)
        else:raise ValueError('corruption_was_accepted:'+name)
    # Keep generated JSON/manifest hashes/counts/XES mutually consistent while
    # swapping train/control. Only the immutable raw corpus binding catches it.
    lineage=args.output/'lineage';folder=lineage/'inputs01';folder.mkdir(parents=True)
    for source in (args.base/'inputs01').iterdir():
        A.need(source.is_file() and source.suffix in ('.json','.xes'),'bounded_control_inputs')
        with (folder/source.name).open('xb') as stream:stream.write(A.read(source,1024*1024))
    case=A.load(folder/'linear.json');case['train'],case['held_out']=case['held_out'],case['train'];data=J.encoded(case);(folder/'linear.json').write_bytes(data)
    manifest=A.load(folder/'manifest.json');entry=next(v for v in manifest['cases'] if v['id']=='linear');entry['input_sha256']=A.sha(data)
    for group in ('train','held_out','diagnostic_only'):entry['counts'][group]=[sum(v['count'] for v in case[group]),sum(v['count']*len(v['trace']) for v in case[group])]
    root=ET.fromstring(A.read(folder/'linear.xes'));traces=root.findall('{*}trace');wanted=entry['counts']['train'][0]
    for trace in traces[wanted:]:root.remove(trace)
    xes=ET.tostring(root,encoding='utf-8',xml_declaration=True);(folder/'linear.xes').write_bytes(xes);entry['xes_sha256']=A.sha(xes);(folder/'manifest.json').write_bytes(J.encoded(manifest))
    A.need(A.sha(A.read(folder/'linear.json'))==entry['input_sha256'] and len(ET.fromstring(xes).findall('{*}trace'))==wanted,'coherent_counterfactual')
    try:F.validate(lineage,'original')
    except ValueError as error:A.need(str(error)=='generated_case_exact_frozen_projection','specific_frozen_lineage_refusal');passed.append('refused_coherent_train_control_swap')
    else:raise ValueError('swapped_frozen_input_accepted')
    for filename in ('linear.json','linear.xes','manifest.json'):(folder/filename).write_bytes(A.read(args.base/'inputs01'/filename))
    typed=A.load(folder/'rare_noise.json');A.need(typed['train'][-1]['count']==1,'positive_one_count');typed['train'][-1]['count']=True;data=J.encoded(typed);(folder/'rare_noise.json').write_bytes(data)
    manifest=A.load(folder/'manifest.json');next(v for v in manifest['cases'] if v['id']=='rare_noise')['input_sha256']=A.sha(data);(folder/'manifest.json').write_bytes(J.encoded(manifest))
    try:F.validate(lineage,'original')
    except ValueError as error:A.need(str(error)=='generated_case_exact_frozen_projection','specific_typed_frozen_refusal');passed.append('refused_boolean_frozen_frequency')
    else:raise ValueError('boolean_frequency_accepted_as_one')
    libraries=R.B.api();linear=args.base/'sv-original02/sv-original-r1-linear';other=args.base/'sv-original02/sv-original-r1-exclusive-choice';tree=S.TreeAutomaton(A.load(linear/'tree.json'));producer=A.load(linear/'result.json')
    A.need(producer['export_reimport_status_identical'] is True and producer['export_reimport_metrics_identical'] is True,'positive_producer_booleans')
    _,_,correct=J.original_graph(linear/'model.bpmn',libraries);S.equivalent(tree,correct);passed.append('positive_actual_linear_xml')
    _,_,wrong_xml=J.original_graph(other/'model.bpmn',libraries)
    _,_,wrong_reimport=L.graph(A.load(other/'reimported-model.json'),libraries)
    _,_,wrong_model=L.graph(A.load(other/'model.json'),libraries)
    for name,graph in [('xml_of_another_process',wrong_xml),('reimported_model_of_another_process',wrong_reimport),('saved_model_of_another_process',wrong_model)]:
        try:S.equivalent(tree,graph)
        except ValueError as error:A.need(str(error)=='tree_to_bpmn_accepting_language_changed','specific_language_refusal');passed.append('refused_'+name)
        else:raise ValueError('wrong_language_accepted:'+name)
    J.save(args.output/'proof.json',{'schema_version':1,'status':'S27_INDEPENDENT_AUDITORS_POSITIVE_AND_COUNTERFACTUAL_CONTROLS_PASS','checks':passed,'producer_booleans_kept_true_for_wrong_xml_test':True,'no_miner_called':True})
    print(json.dumps({'status':'S27_AUDITOR_CONTROLS_PASS','checks':len(passed)}))
if __name__=='__main__':main()
