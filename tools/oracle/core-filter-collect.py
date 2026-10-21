"""Collect actual closed native observations; never repair frozen hypotheses."""
import hashlib,json,sys
from pathlib import Path

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p): return json.loads(p.read_text(encoding='utf-8-sig'))
root=Path(__file__).resolve().parents[2]
attempt=Path(sys.argv[1]).resolve()
if not attempt.is_relative_to(root/'.local/sprint18/service'): raise ValueError('private scope')
manifest=root/'fixtures/oracle-core-filter/corpus.json'
if sha(manifest)!='0997acc2af6514c0d799181f78cfef217bddb375def14646f6864f8257cfce6c': raise ValueError('frozen corpus')
plan=load(attempt/'execution-plan.json'); corpus=load(manifest); rows=[]
for spec,run in zip(corpus['cases'],plan['cases'],strict=True):
    if spec['id']!=run['id']: raise ValueError('ordered plan')
    native=[]
    for label in ('child','worker'):
        p=attempt/spec['id']/(label+'.process.json'); n=load(p)
        if n['native_exit']!=0 or not n['stdout_complete'] or not n['stderr_complete'] or any(n[k] for k in ('capture_fault','drain_timeout','output_limit')): raise ValueError('native failure '+spec['id'])
        for stream in ('stdout','stderr'):
            q=p.parent/(label+'.'+stream)
            if sha(q).upper()!=n[stream+'_sha256'] or q.stat().st_size!=n[stream+'_bytes_persisted']: raise ValueError('full stream binding')
        native.append({'path':str(p),'sha256':sha(p),'value':n})
    p=Path(run['observation']); actual=load(p); fixture=load(manifest.parent/spec['file']); expected=spec['expected_java']
    checks={'status':actual['status']==expected['status'],'engine_invoked':actual['engine_invoked']==expected['engine_invoked'],
            'input_binding':actual['input_sha256']==spec['sha256'],'source_domain_exact':actual['source_domain_before']==fixture['source']==actual['source_domain_after'],
            'source_domain_hash':actual['source_domain_before_sha256']==actual['source_domain_after_sha256'],
            'source_xlog_unchanged':actual['source_xlog_before']==actual['source_xlog_after_conversion'] and (actual['status']!='filtered' or actual['source_xlog_before']==actual['source_xlog_after_filter'])}
    if actual['status']=='filtered':
        indices=actual['selected_source_indices']; selected=actual['selected_source_log']; source=fixture['source']
        checks.update(selected_indices=indices==expected['selected_trace_indices'],selected_ids=[c['id'] for c in selected['cases']]==expected['selected_source_case_ids'],
            source_apm_unchanged=actual['source_apm_before']==actual['source_apm_after'],source_apm_hash=actual['source_apm_before_sha256']==actual['source_apm_after_sha256'],
            full_selected_source_identity=selected==dict(source,cases=[source['cases'][i] for i in indices]),one_actual_call=actual['engine_call_count']==1)
    else: checks['actual_exception']=actual['exception']['root']['class']==expected['exception_class']
    rows.append({'id':spec['id'],'profile':spec['profile'],'fixture_sha256':spec['sha256'],'observation_path':str(p),'observation_sha256':sha(p),'checks':checks,'all_checks':all(checks.values()),'native':native,'observation':actual})
result={'schema_version':1,'status':'ACTUAL_GENUINE_ENGINE_REFERENCE_WITH_FROZEN_MANUAL_CHECKS','corpus_sha256':sha(manifest),'execution_plan_sha256':sha(attempt/'execution-plan.json'),'case_count':len(rows),'manual_passed':sum(r['all_checks'] for r in rows),'cases':rows,'scope':'Six overlap + two declared diagnostics; not all Core/R5. No expected hypotheses rewritten.'}
out=attempt/'reference-results.json'
with out.open('x',encoding='utf-8') as f: json.dump(result,f,ensure_ascii=False,indent=2)
print(json.dumps({'path':str(out),'sha256':sha(out),'manual_passed':result['manual_passed'],'cases':len(rows)}))
