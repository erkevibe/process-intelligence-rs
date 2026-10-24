"""Run the unchanged, source-pinned PM4Py quality reference on new saved nets.
No miner is called; comparison uses the exact net already scored by Rust.
"""
import argparse,importlib.util,json,math
from fractions import Fraction
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
A=module('s27_audit',ROOT/'tools/sprint27/audit-rust-comparison.py')
B=module('s19_reference',ROOT/'tools/sprint19/quality-reference.py')
def close(left,right):A.need(isinstance(left,(int,float)) and math.isfinite(left) and abs(left-float(right))<=1e-9,'reference_scalar_disagreement')
def compare(report,reference,rows):
    metrics=report['metrics'];rf=reference['fitness'];actual=metrics['fitness'];A.need(rf['status']==actual['status']=='measured','fitness_status')
    for key,expected in [('log_fitness',rf['log_fitness']),('average_fitness',rf['average_trace_fitness']),('perfectly_fitting_frac',rf['perfectly_fitting_frac'])]:close(actual['fitness'][key],Fraction(expected))
    integers=actual['integer_components'];A.need(integers['weighted_total_cost']==rf['total_cost'] and integers['log_denominator']==rf['denominator'] and integers['empty_cost']==rf['empty_alignment']['cost'],'fitness_integer_components')
    A.need(integers['traces']==sum(v['frequency'] for v in rows) and integers['events']==sum(v['frequency']*len(v['sequence']) for v in rows),'fitness_input_coverage')
    rp=reference['precision'];ap=metrics['precision'];A.need(rp['status']==ap['status'],'precision_status')
    if rp['status']=='measured':
        close(ap['scalar'],rp['scalar']);A.need(ap['activated_weight']==rp['activated_weight'] and ap['escaping_weight']==rp['escaping_weight'],'precision_integer_components')
    else:A.need(ap.get('scalar') is None,'nonnumeric_precision')
    close(metrics['simplicity']['scalar'],reference['simplicity']['scalar'])
    return {'fitness':rf['log_fitness'],'precision_status':rp['status'],'precision':rp.get('rational'),'simplicity':reference['simplicity']['scalar']}
def main():
    p=argparse.ArgumentParser();p.add_argument('run',type=Path);p.add_argument('audit',type=Path);p.add_argument('output',type=Path);args=p.parse_args()
    A.need(args.output.is_dir() and not any(args.output.iterdir()),'new_empty_output')
    audited=A.load(args.audit/'audit.json');A.need(audited['status']=='S27_RUST_CAPTURES_GRAPHS_INPUTS_AND_REPEATS_AUDITED' and audited['native_proof_sha256']==A.sha(A.read(args.run/'proof.json')),'audited_native_run')
    audited_rows={(r['algorithm'],r['case']):r for r in audited['matrix_rows'] if r['repetition']==1}
    libraries=B.api();results=[];expected=set();caps={'reachable_markings':1000,'fitness_search_states':1000,'prefix_search_states':1000,'tau_closure_markings':1000}
    for directory in sorted(args.run.iterdir()):
        if not directory.is_dir() or '-r1-' not in directory.name:continue
        result=A.load(directory/'result.json')
        source=audited_rows[(result['algorithm'],result['case'])];A.need(A.sha(A.read(directory/'result.json'))==source['artifacts']['result.json'],'audited_result_pin')
        if result['status']!='modelled':continue
        raw=A.read(directory/'bpmn-net.json');net=A.load(directory/'bpmn-net.json')
        A.need(A.sha(raw)==source['artifacts']['bpmn-net.json'],'audited_net_pin')
        for group,file in [('training','train.json'),('held_out','held-out.json'),('diagnostic_only','diagnostic-only.json')]:
            if group not in result:continue
            expected.add((result['algorithm'],result['case'],group))
            rows=A.load(directory/file)
            reference=B.evaluate(net,rows,libraries,A.sha(raw),caps)
            A.need(result[group]['status']=='evaluated','rust_measurement_missing')
            checked=compare(result[group]['report'],reference,rows)
            name=directory.name+'-'+group+'.json'
            with (args.output/name).open('xb') as stream:stream.write(B.encoded(reference))
            results.append({'case':result['case'],'algorithm':result['algorithm'],'group':group,'reference_file':name,'reference_sha256':A.sha(A.read(args.output/name)),'comparison':checked})
    A.need({(r['algorithm'],r['case'],r['group']) for r in results}==expected and len(results)==len(expected),'complete_modelled_group_reference_coverage')
    summary={'schema_version':1,'status':'S27_UNCHANGED_PM4PY_REFERENCE_MATCHES_ALL_RUST_MEASURED_GROUPS','audited_input_sha256':A.sha(A.read(args.audit/'audit.json')),'pm4py_version':'2.7.17','reference_adapter_sha256':A.sha(A.read(ROOT/'tools/sprint19/quality-reference.py')),'source_pins':libraries['pins'],'groups':results,'training_and_control_separate':True,'scope':'Exact saved BPMN-derived nets; upstream Alpha conversion equivalence is audited separately.'}
    with (args.output/'proof.json').open('x',encoding='utf-8',newline='\n') as stream:json.dump(summary,stream,sort_keys=True,ensure_ascii=False,indent=2);stream.write('\n')
    print(json.dumps({'status':summary['status'],'groups':len(results)}))
if __name__=='__main__':main()
