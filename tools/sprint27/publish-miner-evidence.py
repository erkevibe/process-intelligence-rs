"""Project only reviewed synthetic artifacts and bounded, path-free receipts.

No raw server/browser responses, cookies, classpaths or user paths are published.
Real executions remain private; public native summaries bind their complete
stream hashes. No mining or PM4Py import is performed by this projector.
"""
import argparse,csv,importlib.util,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
A=module('s27_publish_audit',ROOT/'tools/sprint27/audit-rust-comparison.py')
R=module('s27_publish_reference',ROOT/'tools/sprint27/reference-rust-comparison.py')
F=module('s27_publish_frozen',ROOT/'tools/sprint27/frozen-inputs.py')
SPECS=[('rust02','rust','original','audits01/reference','audits01/graphs/audit.json',28),('alpha-original01','rust','original','alpha-audit-original03/reference','alpha-audit-original03/graphs/audit.json',28),('alpha-validation01','rust','validation','alpha-audit-validation01/reference','alpha-audit-validation01/graphs/audit.json',28),('java01','java','original','java-audit02/reference','java-audit02/reference/proof.json',14),('inductive02','im',None,'inductive-audit03/reference','inductive-audit03/reference/proof.json',28),('sv-original02','structured','original','sv-audit02/reference','sv-audit02/reference/proof.json',14),('sv-validation01','structured','validation','sv-audit02/reference','sv-audit02/reference/proof.json',14),('sv-structured01','structured','structured','sv-audit02/reference','sv-audit02/reference/proof.json',14)]
ALLOW=('result.json','model.json','model.bpmn','reimported-model.json','bpmn-net.json','bpmn-graph.json','tree.json','upstream-net.json','upstream-graph.json','train.json','held-out.json','diagnostic-only.json')
def encoded(value):return (json.dumps(value,sort_keys=True,ensure_ascii=False,indent=2,allow_nan=False)+'\n').encode()
def reason_core(value):
    if isinstance(value,str):return value[:1024]
    if isinstance(value,dict):return {key:reason_core(value[key]) for key in ('status','reason','code','class','message','exception_class','issue') if key in value and value[key] is not None}
    return value if value is None or type(value) in (int,float,bool) else 'Diagnostic payload retained privately by native result SHA.'
def main():
    p=argparse.ArgumentParser();p.add_argument('base',type=Path);p.add_argument('output',type=Path);args=p.parse_args();base=args.base.absolute();out=args.output.absolute()
    A.need(out.parent==base and re.fullmatch('public-projection[0-9]{2}',out.name),'bounded_private_projection_destination');out.mkdir(parents=True,exist_ok=True);A.need(not any(out.iterdir()),'new_empty_public_projection')
    inventory={};used=0
    def put(name,data):
        nonlocal used
        path=Path(name);A.need(not path.is_absolute() and '..' not in path.parts and name not in inventory and len(data)<=2*1024*1024,'bounded_projection_file:'+name+':'+str(len(data)))
        used+=len(data);A.need(used<=48*1024*1024 and len(inventory)<1000,'bounded_public_total');target=out/path;target.parent.mkdir(parents=True,exist_ok=True)
        with target.open('xb') as stream:stream.write(data)
        inventory[name]={'sha256':A.sha(data),'bytes':len(data)}
    def emit(name,value):put(name,encoded(value))
    manifests={name:F.validate(base,name) for name in F.SETS};cases={name:{c['id']:c for c in manifest['cases']} for name,manifest in manifests.items()}
    native=[];rows=[];model_dirs={};seen_metrics={};audits={};source_pins={}
    projection={r['label']:r for r in A.load(base/'projection02/models/proof.json')['cases']}
    for run_name,kind,known_corpus,reference_path,audit_path,count in SPECS:
        run=base/run_name;proof,config=A.native(run,count);audited=A.load(base/audit_path);audits[audit_path]=A.sha(A.read(base/audit_path))
        audit_rows=audited.get('rows',audited.get('matrix_rows',[]));by_label={r.get('label',r.get('native_label')):r for r in audit_rows}
        phase={'run':run_name,'native_proof_sha256':A.sha(A.read(run/'proof.json')),'config_sha256':A.sha(A.read(run/'config.json')),'process_invocations':count,'records':[]}
        for pin in config['pins']:
            path=Path(pin['path'])
            if path.is_relative_to(ROOT):
                relative=path.relative_to(ROOT).as_posix()
                if relative.startswith(('src/','examples/','tools/','fixtures/','docs/')) or relative in ('Cargo.toml','Cargo.lock'):source_pins[relative]=pin['sha256'].lower()
        for command in config['commands']:
            label=command['label'];record=proof['records'][label];times=record['lifetime_times_after_exit'];memory=record['lifetime_memory_after_exit'];rep=int(re.search(r'-r([12])-',label).group(1))
            source=A.load(run/label/'result.json');directory=run/label;corpus=known_corpus
            if kind=='java':
                projected=projection[label];case=projected['case'];algorithm='java-splitminer';status=projected['status'];reason=projected.get('reason',projected.get('exception'))
                if status=='model_projected':directory=base/'java-scores02'/label;result=A.load(directory/'result.json');status=result['status']
                else:result=None
            elif kind=='im':
                corpus='original' if label.startswith('im-original-') else 'validation';case=Path(command['arguments'][-2]).stem;algorithm='pm4py-inductive-im';status=source['status'];reason=source.get('reason')
                if status=='model_projected':directory=base/'inductive-scores01'/label;result=A.load(directory/'result.json');status=result['status']
                else:result=None
            else:
                result=source;case=result['case'];algorithm=result['algorithm'];algorithm='alpha-legacy' if algorithm=='alpha' else algorithm;status=result['status'];reason=result.get('issue',result.get('outcome'))
            A.need(case in cases[corpus],'known_case');fixture=cases[corpus][case];frozen=A.load(base/F.SETS[corpus][0]/fixture['input_file'])
            execution={'label':label,'program_sha256':command['sha256'].lower(),'native_exit':record['native_exit'],'source_status':record['source_status'],'stdout_complete':record['stdout_complete'],'stderr_complete':record['stderr_complete'],'stdout_sha256':record['stdout_sha256'].lower(),'stderr_sha256':record['stderr_sha256'].lower(),'lifetime_working_set_peak_bytes':memory['peak_working_set_bytes'],'lifetime_private_commit_peak_bytes':memory['peak_private_commit_bytes'],'elapsed_native_ms':(times['exit_filetime_100ns']-times['creation_filetime_100ns'])/10000,'user_cpu_ms':times['user_cpu_100ns']/10000,'kernel_cpu_ms':times['kernel_cpu_100ns']/10000}
            execution['resource_scope']='retained_native_image_only_not_process_tree'
            execution['engine_cpu_ram_measured']=kind!='im'
            if kind=='im':execution['scope_warning']='Windows venv redirector image; interpreter CPU/RAM not established by these fields. Native wall time includes waiting for child.'
            phase['records'].append(execution)
            row={'algorithm':algorithm,'corpus':corpus,'case':case,'repetition':rep,'status':status,'input_sha256':fixture['input_sha256'],'native_run':run_name,'native_label':label,'execution':execution,'native_result_sha256':A.sha(A.read(run/label/'result.json')),'audit_file':audit_path,'audit_sha256':audits[audit_path]}
            if reason is not None:row['reason']=reason_core(reason);row['private_diagnostic_sha256']=A.sha(encoded(reason))
            if status=='modelled':
                required=R.required_groups(result,frozen);A.need(result['input_sha256']==fixture['input_sha256'],'actual_scored_input')
                measured={group:result[group] for group in sorted(required)};key=(algorithm,corpus,case);different=key in seen_metrics and (seen_metrics[key][0]!=result['model_sha256'] or seen_metrics[key][1]!=measured)
                copy_artifacts=rep==1 or different;folder=algorithm+'/'+corpus+'/'+case+('/repeat2' if rep==2 and different else '')
                if copy_artifacts:
                    for filename in ALLOW:
                        source_file=directory/filename
                        if source_file.is_file():put(folder+'/'+filename,A.read(source_file,2*1024*1024))
                    if kind=='java':
                        put(folder+'/original.bpmn',A.read(run/label/'model.bpmn'));emit(folder+'/source-bpmn-graph.json',source['graph'])
                        for suffix in ('net','graph'):put(folder+'/original-'+suffix+'.json',A.read(base/reference_path/(label+'-original-'+suffix+'.json')))
                    if kind=='im':
                        for filename in ('original.bpmn','original-net.json','original-graph.json','tree.txt'):put(folder+'/'+filename,A.read(run/label/filename))
                    if kind=='structured':
                        for stage in ('xml','reimported'):
                            for suffix in ('net','graph'):put(folder+'/audited-'+stage+'-'+suffix+'.json',A.read(base/reference_path/(label+'-'+stage+'-'+suffix+'.json')))
                    model_dirs[key]=folder
                else:folder=model_dirs[key]
                for group,file in [('training','train.json'),('held_out','held-out.json'),('diagnostic_only','diagnostic-only.json')]:
                    if group not in required:continue
                    ref_name=label+'-'+group+('-reference.json' if kind in ('java','im','structured') else '.json');ref_file=base/reference_path/ref_name
                    # Earlier Rust references cover r1; the audited r2 is exactly
                    # identical. A changed r2 is never allowed this substitution.
                    if not ref_file.exists():A.need(rep==2 and not different,'reference_repeat_binding');ref_file=base/reference_path/ref_name.replace('-r2-','-r1-')
                    reference=A.load(ref_file);R.compare(result[group]['report'],reference,A.load(directory/file))
                    if copy_artifacts:put(folder+'/reference-'+group+'.json',A.read(ref_file,2*1024*1024))
                compact={group:{'fitness':value['report']['metrics']['fitness']['fitness']['log_fitness'],'precision':value['report']['metrics']['precision'].get('scalar'),'precision_status':value['report']['metrics']['precision']['status'],'simplicity':value['report']['metrics']['simplicity']['scalar']} for group,value in measured.items()}
                row.update(model_sha256=result['model_sha256'],artifact_folder=folder,groups=compact,repeat_identity_matches_first=(not different))
                observed=by_label.get(label)
                if observed:
                    for field in ('soundness','tree_language_equivalence','saved_model_language_equivalence','actual_xml_language_equivalence','reimported_model_language_equivalence','original_xml_language_equivalence','upstream_language_equivalence'): 
                        if field in observed:row[field]=observed[field]
                seen_metrics.setdefault(key,(result['model_sha256'],measured))
            rows.append(row)
        native.append(phase)
    A.need(len(rows)==168 and sum(r['repetition']==1 for r in rows)==84,'complete_public_comparison_matrix')
    im=A.load(base/'inductive-audit03/reference/proof.json');A.need(im['candidate_acceptance']['deterministic_repeat'] is False,'recorded_im_reproducibility_failure_not_erased')
    compiler=A.load(base/'compile04/proof.json');A.need(compiler['status']=='DIRECT_OWNED_CARGO_COMMANDS_CLOSED' and all(r['native_exit']==0 and r['stdout_complete'] and r['stderr_complete'] for r in compiler['records']),'actual_compiler_closure')
    calibration=A.load(base/'counter-calibration02/proof.json');limit=A.load(base/'limit-calibration01/proof.json')
    scope=A.load(base/'python-image-scope01/proof.json');A.need(scope['status']=='S27_WINDOWS_VENV_REDIRECTOR_SCOPE_CONFIRMED' and scope['venv_runtime_pid_differs_from_retained_image'] is True and scope['direct_runtime_pid_matches_retained_image'] is True,'actual_interpreter_scope_control')
    emit('python-resource-scope.json',{'schema_version':1,'native_proof_sha256':A.sha(A.read(base/'python-image-scope01/proof.json')),'status':scope['status'],'venv_runtime_pid_differs_from_retained_image':True,'direct_runtime_pid_matches_retained_image':True,'python_versions_identical':scope['python_versions_identical'],'conclusion':scope['conclusion']})
    emit('comparison.json',{'schema_version':1,'status':'S27_AUDITED_EXPERIMENTAL_COMPARISON','rows':rows,'corpora':{name:{'path':F.SETS[name][1],'sha256':F.SETS[name][2]} for name in F.SETS},'im_repeat_observations':im['repeat_observations'],'candidate_selection':{'algorithm':'structured_variants_v1','status':'selected_for_bounded_product_integration','product_integration_complete':False,'scope':'Own bounded heuristic, not a full IM or SplitMiner port; no general soundness or quality guarantee.'},'limits':{'training_traces':64,'training_events':500,'training_activities':6,'training_variants':32,'events_per_trace':64,'application_graph_states':1000,'per_evaluation_cooperative_seconds':30,'outer_process_seconds':60,'new_candidate_private_commit_bytes':536870912},'measurement_policy':'Two repetitions are observations, not a statistical benchmark. Rust images include mining, conversion, export and evaluation; Java images mine/export. Counters cover one retained image, not a process tree. Python venv images are redirectors: interpreter CPU/RAM is NOT established by those counters; wall time includes waiting for child. Working set includes shared pages; private commit is distinct. No cross-scope speed or memory ranking.'})
    emit('native-summary.json',{'schema_version':1,'phases':native,'implementations':{'rust_alpha':'process_mining@0.6.2; actual per-run configs retained in result artifacts','java_splitminer':{'class':'org.apromore.splitminer.SplitMiner','class_sha256':'e8535a6b65b7e758a49e757d635e8797071b8e860bc8d1c6859e592eb1ee21ad','apromore_core_source_commit':'bbf24dfd43e72d6992392465f875a4367cbe792b','parameters':A.load(base/'java01/split-r1-linear/result.json')['parameters'],'ordered_runtime_classpath_entries':202},'python_inductive':'Actual PM4Py2.7.17 Variants.IM, parameters{}, not a Rust implementation','native_structured':'Own structured_variants_v1, fixed cut order, no noise filtering; source independently reviewed before mining'},'source_raw_byte_pins':source_pins,'audited_proof_pins':audits,'compile04_proof_sha256':A.sha(A.read(base/'compile04/proof.json')),'compiler_commands':[{'native_exit':r['native_exit'],'stdout_sha256':r['stdout_sha256'],'stderr_sha256':r['stderr_sha256']} for r in compiler['records']],'counter_calibration_proof_sha256':A.sha(A.read(base/'counter-calibration02/proof.json')),'counter_calibration_status':calibration['status'],'memory_limit_proof_sha256':A.sha(A.read(base/'limit-calibration01/proof.json')),'memory_limit_status':limit['status'],'raw_private_logs_not_projected':True})
    for name in ('structured-source-review01','structured-auditors-source-review01','structured-numerical-review01','structured-reference-encoding-review01','inductive-numerical-review01'):
        source=base.parent/'sprint27-review'/(name+'.json');record=A.load(source)
        def scrub(value):
            if isinstance(value,str):return value.replace(str(ROOT),'workspace').replace(ROOT.as_posix(),'workspace')
            if isinstance(value,list):return [scrub(v) for v in value]
            if isinstance(value,dict):return {scrub(k):scrub(v) for k,v in value.items()}
            return value
        emit('review/'+name+'.json',{'original_private_receipt_sha256':A.sha(A.read(source)),'projection_policy':'Only the known workspace prefix is replaced by literal workspace; original receipt remains private and byte-pinned.','review':scrub(record)})
    emit('limitations.json',{'schema_version':1,'failed_attempts':{'java-scores01':'resource_sample_timeout; not accepted','alpha-audit-original01':'resource_sample_timeout; not accepted','alpha-audit-original02':'auditor label parsing bug; original03 closes it','java-audit01':'tuple/list graph adapter bug; java-audit02 closes it','inductive01':'UUID mapping serialization bug; inductive02 closes it','compile03':'missing semicolon; compile04 closes it','structured01':'native IPC label shape; phases split within unchanged registry/label bounds','inductive-audit01':'actual exporter prefixes flow IDs; exact policy recorded in later audit','inductive-audit02':'real repeat instability; retained as failed candidate gate in audit03'},'licenses_observed':{'own_structured_source':'MIT repository license','process_mining_0_6_2':'MIT OR Apache-2.0 crate metadata','actual_splitminer_class_source_header':'LGPL-3.0-or-later; full multi-entry Java runtime requires separate dependency review before distribution','pm4py_2_7_17':'AGPL3 package metadata; existing experimental/reference environment, not shipped by this change'},'precision_limitations':'Repeat/generalization permits more behavior; observed third-corpus repeated-label precision0.5 is retained, not described as universal quality.'})
    # The manifest is intentionally outside its own file inventory.
    with (out/'manifest.json').open('xb') as stream:stream.write(encoded({'schema_version':1,'status':'S27_SYNTHETIC_PUBLIC_EVIDENCE_PROJECTED','files':inventory,'total_bytes':used,'source_phases':len(native),'matrix_rows':len(rows)}))
    print(json.dumps({'status':'S27_PUBLIC_PROJECTION_WRITTEN','files':len(inventory),'bytes':used,'rows':len(rows)}))
if __name__=='__main__':main()
