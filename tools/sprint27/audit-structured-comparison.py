"""Independent process-tree automaton, finite-net soundness and metric checks.

Tree language uses a separate epsilon-NFA/shuffle construction, never the Rust
gateway builder. No finite trace-depth approximation is used for equivalence.
"""
import argparse, importlib.util, json
from collections import deque
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
A=module('s27_audit',ROOT/'tools/sprint27/audit-rust-comparison.py')
R=module('s27_reference',ROOT/'tools/sprint27/reference-rust-comparison.py')
F=module('s27_frozen',ROOT/'tools/sprint27/frozen-inputs.py')
J=module('s27_xml',ROOT/'tools/sprint27/audit-java-comparison.py')
L=module('s27_model',ROOT/'tools/sprint27/model-language.py')
CORPORA={'original':('inputs01',A.CORPUS),'validation':('inputs02','891b1f4306850ac0abd02a2afaeafa61a892847fbf2e73a44b02bdc06bbafa17'),'structured':('inputs03','a6db9120518d4adfdfcb2648c6bba08efbd2757b4a36be50aafb50db795018e6')}
def save(path,value):
    with path.open('x',encoding='utf-8') as stream:json.dump(value,stream,sort_keys=True,ensure_ascii=False,allow_nan=False,indent=2);stream.write('\n')
class TreeAutomaton:
    def __init__(self,tree):
        self.edges=[];self.initial,self.final=self.build(tree,0)
    def node(self):
        A.need(len(self.edges)<2048,'tree_automaton_state_budget');self.edges.append([]);return len(self.edges)-1
    def arc(self,a,b,label):
        if (label,b) not in self.edges[a]:self.edges[a].append((label,b))
        A.need(sum(map(len,self.edges))<=10000,'tree_automaton_edge_budget')
    def build(self,tree,depth):
        A.need(depth<=32 and isinstance(tree,dict) and set(tree)<={'operator','children'},'bounded_tree_schema')
        op=tree['operator'];a,b=self.node(),self.node()
        if op=='tau':A.need(set(tree)=={'operator'},'tau_schema');self.arc(a,b,None)
        elif op=='task':
            label=tree['children'];A.need(isinstance(label,str) and 0<len(label.encode())<=200,'tree_task');self.arc(a,b,label)
        elif op=='repeat':
            x,y=self.build(tree['children'],depth+1);self.arc(a,x,None);self.arc(y,x,None);self.arc(y,b,None)
        else:
            children=tree['children'];A.need(op in ('sequence','choice','parallel') and isinstance(children,list) and 2<=len(children)<=64,'tree_operator')
            ends=[self.build(child,depth+1) for child in children]
            if op=='sequence':
                previous=a
                for x,y in ends:self.arc(previous,x,None);previous=y
                self.arc(previous,b,None)
            elif op=='choice':
                for x,y in ends:self.arc(a,x,None);self.arc(y,b,None)
            else:
                initial=tuple(x for x,_ in ends);final=tuple(y for _,y in ends);states={initial:self.node()};todo=deque([initial]);self.arc(a,states[initial],None)
                while todo:
                    current=todo.popleft()
                    if current==final:self.arc(states[current],b,None)
                    for index,state in enumerate(current):
                        for label,dest in list(self.edges[state]):
                            following=current[:index]+(dest,)+current[index+1:]
                            if following not in states:states[following]=self.node();todo.append(following)
                            self.arc(states[current],states[following],label)
        return a,b
    def accepts(self,trace):
        states=A.EQUIVALENCE.closure({self.initial},self.edges)
        for label in trace:states=A.EQUIVALENCE.advance(states,label,self.edges)
        return self.final in states
def equivalent(tree,graph):
    ri,rf,re=A.EQUIVALENCE.validate(graph)
    start=(A.EQUIVALENCE.closure({tree.initial},tree.edges),A.EQUIVALENCE.closure({ri},re));todo=deque([start]);seen={start}
    while todo:
        left,right=todo.popleft();A.need((tree.final in left)==bool(right&rf),'tree_to_bpmn_accepting_language_changed')
        alphabet={label for s in left for label,_ in tree.edges[s] if label is not None}|{label for s in right for label,_ in re[s] if label is not None}
        for label in sorted(alphabet):
            following=(A.EQUIVALENCE.advance(left,label,tree.edges),A.EQUIVALENCE.advance(right,label,re))
            if following in seen:continue
            A.need(len(seen)<1000,'tree_language_equivalence_budget');seen.add(following);todo.append(following)
    return {'status':'equivalent','method':'independent_tree_epsilon_nfa_and_parallel_shuffle_complete_language','subset_pairs':len(seen),'tree_automaton_states':len(tree.edges)}
def main():
    p=argparse.ArgumentParser();p.add_argument('run',type=Path);p.add_argument('inputs_base',type=Path);p.add_argument('output',type=Path);args=p.parse_args()
    A.need(args.output.is_dir() and not any(args.output.iterdir()),'new_empty_output')
    series=A.load(args.run/'manifest.json');A.need(series['schema_version']==1 and series['status']=='S27_STRUCTURED_THREE_CORPORA_CAPTURED' and {r['corpus'] for r in series['runs']}==set(CORPORA) and len(series['runs'])==3,'closed_series')
    commands=[];native_hashes={}
    for item in series['runs']:
        A.need(isinstance(item['directory'],str) and item['directory'].replace('-','').isalnum() and '/' not in item['directory'] and '\\' not in item['directory'],'series_run_boundary')
        run=args.inputs_base/item['directory'];proof,config=A.native(run,14)
        A.need(proof['corpus']==item['corpus'] and A.sha(A.read(run/'proof.json'))==item['proof_sha256'],'series_proof_binding')
        native_hashes[item['corpus']]=item['proof_sha256'];commands.extend(config['commands'])
    expected={}
    for name,(directory,sha) in CORPORA.items():
        manifest=F.validate(args.inputs_base,name);A.need(manifest['corpus_sha256']==sha,'prospective_corpus')
        for rep in (1,2):
            for case in manifest['cases']:expected['sv-'+name+'-r'+str(rep)+'-'+case['id'].replace('_','-')]=(name,rep,case,directory)
    A.need(len(commands)==42 and set(expected)=={c['label'] for c in commands},'complete_prospective_matrix')
    libraries=R.B.api();rows=[];groups=[];results={};expected_groups=set();caps={'reachable_markings':1000,'fitness_search_states':1000,'prefix_search_states':1000,'tau_closure_markings':1000}
    for command in commands:
        label=command['label'];name,rep,case,input_dir=expected[label];input_path=args.inputs_base/input_dir/case['input_file'];source=A.load(input_path);directory=Path(command['arguments'][-1]);result=A.load(directory/'result.json')
        A.need(result['input_sha256']==case['input_sha256']==A.sha(A.read(input_path)) and result['case']==case['id'] and result['algorithm']=='structured_variants_v1' and result['held_out_supplied_to_miner'] is False,'exact_case_binding')
        A.need([str(input_path),str(directory)]==command['arguments'],'native_input_output_binding')
        row={'label':label,'corpus':name,'case':case['id'],'repetition':rep,'status':result['status']}
        if not source['train']:A.need(result['status']=='no_data','empty_training_is_no_data')
        elif result['status']=='modelled':
            required=R.required_groups(result,source);expected_groups.update((label,group) for group in required)
            raw=A.read(directory/'bpmn-net.json');net=A.load(directory/'bpmn-net.json');graph=A.load(directory/'bpmn-graph.json');A.CONSERVATION.validate(raw,graph)
            sound=A.soundness(net,graph);A.need(sound['finite_complete_graph_sound'] and sound['one_safe'],'structured_model_unsound')
            tree=TreeAutomaton(A.load(directory/'tree.json'));language=equivalent(tree,graph)
            model_net,model_raw,model_graph=L.graph(A.load(directory/'model.json'),libraries)
            model_language=equivalent(tree,model_graph)
            xml_net,xml_raw,xml_graph=J.original_graph(directory/'model.bpmn',libraries)
            xml_language=equivalent(tree,xml_graph)
            reimported_net,reimported_raw,reimported_graph=L.graph(A.load(directory/'reimported-model.json'),libraries)
            reimported_language=equivalent(tree,reimported_graph)
            save(args.output/(label+'-xml-net.json'),xml_net);save(args.output/(label+'-xml-graph.json'),xml_graph)
            save(args.output/(label+'-reimported-net.json'),reimported_net);save(args.output/(label+'-reimported-graph.json'),reimported_graph)
            A.need(all(tree.accepts(v['trace']) for v in source['train']),'tree_does_not_accept_all_training_variants')
            A.need(result['model_sha256']==A.sha(A.read(directory/'model.json')) and result['export_reimport_status_identical'] is True and result['export_reimport_metrics_identical'] is True,'exact_roundtrip')
            row.update(soundness=sound,tree_language_equivalence=language,saved_model_language_equivalence=model_language,actual_xml_language_equivalence=xml_language,reimported_model_language_equivalence=reimported_language,model_sha256=result['model_sha256'],fallbacks=result['exact_variant_fallbacks'])
            for group,file,key in [('training','train.json','train'),('held_out','held-out.json','held_out'),('diagnostic_only','diagnostic-only.json','diagnostic_only')]:
                data=A.load(directory/file);A.need(data==[{'sequence':v['trace'],'frequency':v['count']} for v in source[key]],'exact_group_rows')
                if group not in required:continue
                A.need(result[group]['status']=='evaluated','scored_group_required');report=result[group]['report']
                A.need(report['model_sha256']==result['model_sha256'] and report['net_sha256']==A.sha(raw),'exact_report_binding')
                reference=R.B.evaluate(net,data,libraries,A.sha(raw),caps);comparison=R.compare(report,reference,data)
                filename=label+'-'+group+'-reference.json';save(args.output/filename,reference);groups.append({'label':label,'corpus':name,'case':case['id'],'group':group,'comparison':comparison,'reference_file':filename,'reference_sha256':A.sha(A.read(args.output/filename))})
        else:
            A.need(result['status'] in ('not_modelled','not_admitted'),'honest_refusal');row['issue']=result.get('issue')
        results[(name,case['id'],rep)]=result
        row['artifacts']={p.name:A.sha(A.read(p)) for p in directory.iterdir() if p.is_file()};rows.append(row)
    for name,case,rep in results:
        if rep!=1:continue
        left=results[(name,case,1)];right=results[(name,case,2)];A.need(left['status']==right['status'],'repeat_status')
        A.need(left.get('issue')==right.get('issue'),'repeat_refusal_reason')
        if left['status']=='modelled':
            A.need(left['model_sha256']==right['model_sha256'] and left['exact_variant_fallbacks']==right['exact_variant_fallbacks'],'canonical_repeat')
            for group in ('training','held_out','diagnostic_only'):A.need(left.get(group)==right.get(group),'repeat_metrics')
    A.need(len(groups)>0 and len(groups)==len(expected_groups) and {(r['label'],r['group']) for r in groups}==expected_groups,'complete_numeric_group_coverage')
    save(args.output/'proof.json',{'schema_version':1,'status':'S27_STRUCTURED_TREE_LANGUAGE_SOUNDNESS_AND_PM4PY_METRICS_AUDITED','native_proof_sha256':native_hashes,'series_manifest_sha256':A.sha(A.read(args.run/'manifest.json')),'rows':rows,'groups':groups,'pm4py_version':'2.7.17','source_pins':libraries['pins'],'scope':'Exact finite graphs and frozen inputs only; heuristic is not a full Inductive Miner or SplitMiner port.'})
    print(json.dumps({'status':'S27_STRUCTURED_AUDITED','rows':len(rows),'groups':len(groups)}))
if __name__=='__main__':main()
