"""Audit the finite frozen experiment: native captures, net/graph conservation,
observable language equivalence, exact input coverage and repeat identity.
Metric values receive a separate unchanged PM4Py reference check.
"""
import argparse,hashlib,importlib.util,json,math,os
from collections import Counter,deque
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
CORPUS='a00e03010eb1d8f5f8f11e9533abdcf72507c86300ad54e1ac251f74ad7aa68c'
def need(ok,why):
    if not ok:raise ValueError(why)
def sha(raw):return hashlib.sha256(raw).hexdigest()
def unique(pairs):
    result={}
    for key,value in pairs:
        need(key not in result,'duplicate_key');result[key]=value
    return result
def read(path,cap=16*1024*1024):
    path=Path(path).absolute();need(path.is_relative_to(ROOT) and '..' not in path.parts,'workspace_boundary')
    cursor=ROOT
    for part in path.relative_to(ROOT).parts:
        cursor/=part;st=cursor.lstat();need(not cursor.is_symlink() and not getattr(st,'st_file_attributes',0)&1024,'no_reparse')
    need(path.is_file() and path.stat().st_size<=cap,'bounded_file')
    with path.open('rb') as stream:raw=stream.read(cap+1)
    need(len(raw)<=cap,'bounded_read');return raw
def load(path,cap=16*1024*1024):return json.loads(read(path,cap).decode('utf-8-sig'),object_pairs_hook=unique,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite')))
def file_sha(path,cap=512*1024*1024):
    path=Path(path).absolute();need(path.is_relative_to(ROOT) and '..' not in path.parts,'workspace_boundary')
    cursor=ROOT
    for part in path.relative_to(ROOT).parts:
        cursor/=part;st=cursor.lstat();need(not cursor.is_symlink() and not getattr(st,'st_file_attributes',0)&1024,'no_reparse')
    need(path.is_file() and path.stat().st_size<=cap,'bounded_pinned_file')
    digest=hashlib.sha256();used=0
    with path.open('rb') as stream:
        while chunk:=stream.read(1024*1024):
            used+=len(chunk);need(used<=cap,'pinned_file_grew');digest.update(chunk)
    return digest.hexdigest()
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
CONSERVATION=module('s27_conservation',ROOT/'tools/oracle/validate-quality-net-graph.py')
EQUIVALENCE=module('s27_equivalence',ROOT/'tools/oracle/compare-quality-graphs.py')
def native(run,expected):
    proof=load(run/'proof.json');config_raw=read(run/'config.json');need(sha(config_raw)==proof['config_sha256'].lower(),'config_pin')
    config=json.loads(config_raw,object_pairs_hook=unique);commands=config['commands'];labels={c['label'] for c in commands}
    need(len(commands)==expected and len(labels)==expected and set(proof['records'])==labels|{'worker'},'native_coverage')
    for pin in config['pins']:
        path=Path(pin['path']).absolute()
        if path.is_relative_to(ROOT):
            need(file_sha(path)==pin['sha256'].lower(),'actual_source_or_input_pin:'+pin['path'])
        else:
            # The old canonical runtime manifest also pins the Codex host.
            # Do not read arbitrary external files: bind this one known host to
            # its native launch receipt, which already checked the executable.
            expected=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
            start=load(run/'session/worker.start.json')
            need(path==expected and Path(start['program'])==path and pin['sha256']==start['program_sha256']=='362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139','known_external_controller_launch_pin')
    for command in commands:
        need(file_sha(command['program'])==command['sha256'].lower(),'actual_program_pin')
    for label,record in proof['records'].items():
        actual=load(run/'session'/(label+'.process.json'));need(actual==record,'native_receipt_binding')
        need(record['native_exit']==0 and record['stdout_complete'] and record['stderr_complete'] and record['source_status']=='captured','complete_native_exit')
        for stream in ('stdout','stderr'):
            raw=read(run/'session'/(label+'.'+stream),1024*1024)
            need(sha(raw)==record[stream+'_sha256'].lower() and len(raw)==record[stream+'_bytes_persisted'],'native_stream_pin')
        memory=record['lifetime_memory_after_exit'];times=record['lifetime_times_after_exit']
        need(memory['peak_working_set_bytes']>0 and memory['peak_private_commit_bytes']>0,'lifetime_peaks')
        need(times['creation_filetime_100ns']==record['native_creation_filetime'] and times['exit_filetime_100ns']>times['creation_filetime_100ns'],'counter_identity')
    return proof,config

def soundness(net,graph):
    initial=net['initial_marking'];final=net['final_markings'][0]
    single=len(initial)==len(final)==1 and list(initial.values())==list(final.values())==[1]
    all_nodes=set(net['places'])|set(net['transitions']);forward={n:set() for n in all_nodes};backward={n:set() for n in all_nodes}
    for arc in net['arcs']:
        a,b=arc['from_to']['nodes'];forward[a].add(b);backward[b].add(a)
    def reachable(seed,edges):
        found=set(seed);todo=list(seed)
        while todo:
            for dest in edges[todo.pop()]:
                if dest not in found:found.add(dest);todo.append(dest)
        return found
    workflow=single and reachable(initial,forward)==all_nodes and reachable(final,backward)==all_nodes and not any(backward[p] for p in initial) and not any(forward[p] for p in final)
    reverse={i:set() for i in range(len(graph['states']))}
    for edge in graph['edges']:reverse[edge['to']].add(edge['from'])
    can_finish=reachable(graph['final_states'],reverse)==set(reverse)
    target=[final.get(place,0) for place in graph['places']]
    proper=all(state==target or not all(n>=f for n,f in zip(state,target)) for state in graph['states'])
    dead=set(net['transitions'])-{edge['transition'] for edge in graph['edges']}
    one_safe=all(n<=1 for state in graph['states'] for n in state)
    return {'workflow_net':workflow,'option_to_complete':can_finish,'proper_completion':proper,'dead_transitions':len(dead),'one_safe':one_safe,'finite_complete_graph_sound':workflow and can_finish and proper and not dead,'scope':'This exact conserved complete finite graph only; no guarantee for arbitrary miner outputs.'}

def canonical_rows(rows):
    values=Counter()
    for row in rows:values[tuple(row['sequence'])]+=row['frequency']
    return [{'frequency':count,'sequence':list(sequence)} for sequence,count in sorted(values.items())]
def main():
    p=argparse.ArgumentParser();p.add_argument('run',type=Path);p.add_argument('inputs',type=Path);p.add_argument('output',type=Path);args=p.parse_args();run=args.run.absolute();inputs=args.inputs.absolute()
    need(args.output.is_dir() and not any(args.output.iterdir()),'new_empty_output')
    proof,config=native(run,28);manifest=load(inputs/'manifest.json');need(manifest['corpus_sha256'] in (CORPUS,'891b1f4306850ac0abd02a2afaeafa61a892847fbf2e73a44b02bdc06bbafa17') and len(manifest['cases'])==7,'frozen_corpus')
    algorithms=set(proof['algorithms']);need(algorithms in ({'observed','alpha'},{'alpha-default','alpha-repair'}),'prospective_algorithm_set')
    expected={case['id']:case for case in manifest['cases']};seen=set();results={};rows=[]
    for command in config['commands']:
        algorithm,input_file,out=command['arguments'];directory=Path(out);result=load(directory/'result.json');case=expected[result['case']]
        prefix=algorithm+'-r';need(command['label'].startswith(prefix),'algorithm_label_prefix')
        key=(algorithm,int(command['label'][len(prefix):].split('-')[0]),result['case']);need(key not in seen,'duplicate_run');seen.add(key)
        need(result['algorithm']==algorithm and result['input_sha256']==case['input_sha256'] and sha(read(input_file))==case['input_sha256'],'exact_training_control_input')
        frozen=load(input_file);need(result['held_out_supplied_to_miner'] is False,'training_only_declaration')
        for group,file in [('train','train.json'),('held_out','held-out.json'),('diagnostic_only','diagnostic-only.json')]:
            actual=load(directory/file);wanted=[{'sequence':v['trace'],'frequency':v['count']} for v in frozen[group]];need(actual==wanted,'exact_group_coverage')
        row={'algorithm':algorithm,'repetition':key[1],'case':result['case'],'status':result['status'],'native_label':command['label']}
        if result['status']=='modelled':
            model_raw=read(directory/'model.json');load(directory/'model.json');net_raw=read(directory/'bpmn-net.json');net=load(directory/'bpmn-net.json');graph=load(directory/'bpmn-graph.json');CONSERVATION.validate(net_raw,graph)
            need(result['model_sha256']==sha(model_raw),'model_hash');row['soundness']=soundness(net,graph)
            if algorithm.startswith('alpha'):
                original_raw=read(directory/'upstream-net.json');load(directory/'upstream-net.json');original=load(directory/'upstream-graph.json');CONSERVATION.validate(original_raw,original)
                equivalence=EQUIVALENCE.compare(original,graph,1000);need(equivalence['status']=='equivalent','upstream_to_bpmn_language_changed');row['upstream_language_equivalence']=equivalence
            for group,file in [('training','train.json'),('held_out','held-out.json'),('diagnostic_only','diagnostic-only.json')]:
                if group not in result:continue
                measured=result[group]
                if measured['status']!='evaluated':continue
                report=measured['report'];data=load(directory/file);canonical=canonical_rows(data)
                need(report['model_sha256']==sha(model_raw) and report['net_sha256']==sha(net_raw),'report_exact_model_and_net')
                need(report['variants_sha256']==sha(json.dumps(canonical,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()),'report_exact_variants')
                need(report['trace_count']==sum(v['frequency'] for v in data) and report['variant_count']==len(canonical),'reported_coverage')
            need(result['export_reimport_status_identical'] is True,'roundtrip_status')
            if result['held_out']['status']=='evaluated':need(result['export_reimport_metrics_identical'] is True and result['held_out']['report']['metrics']==result['reimported_held_out']['report']['metrics'],'roundtrip_metrics')
            row['model_sha256']=sha(model_raw)
        else:
            need(result['status'] in ('no_data','not_modelled'),'explicit_nonmodel_outcome')
            row['reason']=result.get('outcome',{}).get('issue',{}).get('reason')
        files=list(directory.iterdir());need(len(files)<=16 and all(p.is_file() for p in files),'bounded_output_inventory')
        row['artifacts']={p.name:sha(read(p,8*1024*1024)) for p in files}
        need(sum(p.stat().st_size for p in files)<=16*1024*1024,'bounded_output_total')
        results[key]=(result,directory);rows.append(row)
    need(seen=={(a,r,c) for a in algorithms for r in (1,2) for c in expected},'complete_experiment_matrix')
    for algorithm in sorted(algorithms):
        for case in expected:
            (left,ld),(right,rd)=results[(algorithm,1,case)],results[(algorithm,2,case)]
            need(left['status']==right['status'],'repeat_outcome_changed')
            if left['status']=='modelled':
                need(left['model_sha256']==right['model_sha256'],'canonical_model_repeat_changed')
                for group in ('training','held_out','diagnostic_only'):need(left.get(group)==right.get(group),'repeat_scores_changed')
                need(EQUIVALENCE.compare(load(ld/'bpmn-graph.json'),load(rd/'bpmn-graph.json'),1000)['status']=='equivalent','repeat_language_changed')
    summary={'schema_version':1,'status':'S27_RUST_CAPTURES_GRAPHS_INPUTS_AND_REPEATS_AUDITED','native_proof_sha256':sha(read(run/'proof.json')),'matrix_rows':rows,'metric_reference_pending':True}
    with (args.output/'audit.json').open('x',encoding='utf-8',newline='\n') as stream:json.dump(summary,stream,sort_keys=True,ensure_ascii=False,indent=2);stream.write('\n')
    print(json.dumps({'status':summary['status'],'rows':len(rows)}))
if __name__=='__main__':main()
