"""Portable, standard-library verification of projected experimental evidence.

Replays net conservation, complete saved tree language, strict recorded reference
agreement and the fixed-input binding. It does not rerun mining, authenticate an
author or substitute for the separately captured original XML conversion.
"""
import argparse,importlib.util,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
S=module('s27_public_tree',ROOT/'tools/sprint27/audit-structured-comparison.py');A=S.A;R=S.R;F=S.F
def encoded(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)
def main():
    p=argparse.ArgumentParser();p.add_argument('package',type=Path);args=p.parse_args();package=args.package.absolute();manifest=A.load(package/'manifest.json');files=manifest['files']
    A.need(type(manifest['schema_version']) is int and manifest['schema_version']==1 and manifest['status']=='S27_SYNTHETIC_PUBLIC_EVIDENCE_PROJECTED' and 1<=len(files)<=1000,'bounded_manifest')
    total=0
    for name,record in files.items():
        path=Path(name);A.need(not path.is_absolute() and '..' not in path.parts and re.fullmatch('[a-zA-Z0-9_./-]+',name),'artifact_path')
        data=A.read(package/path,2*1024*1024);A.need(A.sha(data)==record['sha256'] and type(record['bytes']) is int and len(data)==record['bytes'],'actual_artifact_hash');total+=len(data)
        if path.suffix=='.json':
            value=A.load(package/path)
            def safe(v):
                if isinstance(v,str):A.need(not re.search(r'(?i)[a-z]:[\\/]+users[\\/]+',v),'no_absolute_user_path')
                elif isinstance(v,list):
                    for item in v:safe(item)
                elif isinstance(v,dict):
                    for key,item in v.items():safe(key);safe(item)
            safe(value)
    A.need(total==manifest['total_bytes'] and total<=48*1024*1024,'exact_total')
    todo=[package];actual=set();directories=0
    while todo:
        folder=todo.pop();A.need(not folder.is_symlink() and not getattr(folder.lstat(),'st_file_attributes',0)&1024,'no_directory_reparse');directories+=1;A.need(directories<=1000,'bounded_directories')
        for path in folder.iterdir():
            A.need(not path.is_symlink() and not getattr(path.lstat(),'st_file_attributes',0)&1024,'no_artifact_reparse')
            if path.is_dir():todo.append(path)
            else:actual.add(path.relative_to(package).as_posix())
    A.need(actual==set(files)|{'manifest.json'},'exact_package_inventory')
    comparison=A.load(package/'comparison.json');rows=comparison['rows'];A.need(len(rows)==168,'complete_native_invocation_rows')
    corpora={}
    for name,(_,path,sha) in F.SETS.items():
        raw=A.read(ROOT/path);A.need(A.sha(raw)==sha and comparison['corpora'][name]=={'path':path,'sha256':sha},'actual_frozen_source');corpora[name]={c['id']:c for c in A.load(ROOT/path)['cases']}
    algorithms={'original':{'observed','alpha-legacy','alpha-default','alpha-repair','java-splitminer','pm4py-inductive-im','structured_variants_v1'},'validation':{'alpha-default','alpha-repair','pm4py-inductive-im','structured_variants_v1'},'structured':{'structured_variants_v1'}}
    wanted={(algorithm,corpus,case,rep) for corpus,values in algorithms.items() for algorithm in values for case in corpora[corpus] for rep in (1,2)}
    A.need({(r['algorithm'],r['corpus'],r['case'],r['repetition']) for r in rows}==wanted and len(wanted)==len(rows),'exact_full_comparison_matrix')
    checked=set();metric_groups=0;selected=0
    for row in rows:
        corpus=corpora[row['corpus']][row['case']];frozen={key:corpus[key] for key in ('id','train','held_out')};frozen['diagnostic_only']=corpus.get('diagnostic_only',[])
        A.need(row['input_sha256']==A.sha((encoded(frozen)+'\n').encode()),'exact_generated_case_hash')
        execution=row['execution'];A.need(execution['native_exit']==0 and execution['stdout_complete'] is True and execution['stderr_complete'] is True and execution['source_status']=='captured','complete_recorded_native_capture')
        A.need(execution['resource_scope']=='retained_native_image_only_not_process_tree','explicit_resource_scope')
        if row['algorithm']=='pm4py-inductive-im':A.need(execution['engine_cpu_ram_measured'] is False,'do_not_rank_python_redirector_as_engine_ram')
        if row['status']!='modelled':A.need('artifact_folder' not in row and 'groups' not in row,'no_invented_numeric_refusal');continue
        name=row['artifact_folder'];A.need(name+'/result.json' in files,'inventoried_model_folder');folder=package/name;result=A.load(folder/'result.json');required=R.required_groups(result,frozen)
        A.need(result['case']==row['case'] and result['input_sha256']==row['input_sha256'] and result['model_sha256']==row['model_sha256']==A.sha(A.read(folder/'model.json')),'actual_exact_model_binding')
        A.need(set(row['groups'])==required,'all_compact_groups')
        for group,file,key in [('training','train.json','train'),('held_out','held-out.json','held_out'),('diagnostic_only','diagnostic-only.json','diagnostic_only')]:
            data=A.load(folder/file);A.need(encoded(data)==encoded([{'sequence':v['trace'],'frequency':v['count']} for v in frozen[key]]),'exact_frozen_evaluation_rows')
            if group not in required:continue
            A.need(result[group]['status']=='evaluated','actual_measured_group');report=result[group]['report'];reference=A.load(folder/('reference-'+group+'.json'));R.compare(report,reference,data)
            compact=row['groups'][group];metrics=report['metrics'];R.close(compact['fitness'],metrics['fitness']['fitness']['log_fitness']);R.close(compact['simplicity'],metrics['simplicity']['scalar']);A.need(compact['precision_status']==metrics['precision']['status'],'compact_precision_status')
            if metrics['precision'].get('scalar') is None:A.need(compact['precision'] is None,'compact_nonnumeric_precision')
            else:R.close(compact['precision'],metrics['precision']['scalar'])
            metric_groups+=1
        if name in checked:continue
        checked.add(name);raw=A.read(folder/'bpmn-net.json');graph=A.load(folder/'bpmn-graph.json');A.CONSERVATION.validate(raw,graph)
        if row['algorithm']=='structured_variants_v1':
            selected+=1;tree=S.TreeAutomaton(A.load(folder/'tree.json'));S.equivalent(tree,graph);sound=A.soundness(A.load(folder/'bpmn-net.json'),graph);A.need(sound['finite_complete_graph_sound'] and sound['one_safe'],'selected_soundness')
            for stage in ('xml','reimported'):
                net=A.read(folder/('audited-'+stage+'-net.json'));state=A.load(folder/('audited-'+stage+'-graph.json'));A.CONSERVATION.validate(net,state);S.equivalent(tree,state)
        if (folder/'upstream-net.json').is_file():
            original=A.read(folder/'upstream-net.json');upstream=A.load(folder/'upstream-graph.json');A.CONSERVATION.validate(original,upstream);A.need(A.EQUIVALENCE.compare(upstream,graph,1000)['status']=='equivalent','alpha_upstream_language')
        if row['algorithm']=='pm4py-inductive-im':
            original=A.read(folder/'original-net.json');upstream=A.load(folder/'original-graph.json');A.CONSERVATION.validate(original,upstream);A.need(A.EQUIVALENCE.compare(upstream,graph,1000)['status']=='equivalent','actual_im_original_language')
    A.need(selected==18 and len(checked)==55,'complete_projected_models_including_changed_im_repeat')
    observed=comparison['im_repeat_observations'];A.need(any(r['deterministic_candidate_gate'] is False for r in observed),'real_im_failure_retained')
    im=[r for r in rows if r['algorithm']=='pm4py-inductive-im' and r['case']=='two_parallel_chains'];A.need(len(im)==2 and im[0]['model_sha256']!=im[1]['model_sha256'],'actual_changed_repeat_models')
    first=A.load(package/im[0]['artifact_folder']/'bpmn-graph.json');second=A.load(package/im[1]['artifact_folder']/'bpmn-graph.json');A.need(A.EQUIVALENCE.compare(first,second,1000)['status']=='not_equivalent','actual_changed_repeat_languages')
    A.need(comparison['candidate_selection']['algorithm']=='structured_variants_v1' and comparison['candidate_selection']['product_integration_complete'] is False,'honest_experimental_selection')
    print(json.dumps({'status':'S27_PORTABLE_PUBLIC_EVIDENCE_AUDIT_PASS','files':len(files),'bytes':total,'rows':len(rows),'model_folders':len(checked),'selected_model_folders':selected,'numeric_group_checks_including_repeat_rows':metric_groups,'mining_rerun':False,'author_signature_verified':False}))
if __name__=='__main__':main()
