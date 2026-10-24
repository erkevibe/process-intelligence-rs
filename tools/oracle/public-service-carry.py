"""Bind exact null-only observer repair and unchanged reachable old observations."""
import difflib
import hashlib
import json
from pathlib import Path

workspace=Path(__file__).resolve().parents[2]
base=workspace/'.local/sprint18/service'
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path): return json.loads(path.read_text(encoding='utf-8-sig'))
old_source=base/'preserved-harness-2d8d.java'
new_source=workspace/'tools/oracle/public-service-harness.java'
assert sha(old_source)=='2d8d30cac64306f1d8feb9dbe93fce4bfa6b8f73308e4a8ae9fdba3f828e687e'
assert sha(new_source)=='e3f4e4a6b5a4de38280855b2b2581468da15e611595387b2a8f0b9cebc463610'
old=old_source.read_text(encoding='utf-8');new=new_source.read_text(encoding='utf-8')
before='              "reloaded_log",PublicServiceXesObserver.log(xlog),"apm_cache_class",apm==null?null:apm.getClass().getName());'
after='              "reloaded_log",xlog==null?null:PublicServiceXesObserver.log(xlog),\n              "reloaded_log_status",xlog==null?"actual_service_returned_null":"available",\n              "apm_cache_class",apm==null?null:apm.getClass().getName());'
assert old.count(before)==1 and old.replace(before,after)==new
old_plan=read(base/'corpus01/execution-plan.json');new_plan=read(base/'corpus02/targeted-plan.json')
carried=[]
def reloaded_fields(value,path=''):
    if isinstance(value,dict):
        for key,child in value.items():
            p=path+'/'+key
            if key=='reloaded_log':
                assert child is not None,'cannot carry observed null branch'
                yield p
            yield from reloaded_fields(child,p)
    elif isinstance(value,list):
        for i,child in enumerate(value): yield from reloaded_fields(child,path+'/'+str(i))
for case in old_plan['cases']:
    if case['id'] in {'all-filtered','flat-wide-types'}: continue
    path=Path(case['observation']);observed=read(path)
    fields=list(reloaded_fields(observed))
    carried.append({'id':case['id'],'observation_sha256':sha(path),'non_null_reloaded_fields':fields,
                    'no_saved_readback_on_public_exception_or_outer_rollback':not fields,
                    'old_adapter_source_sha256':sha(old_source),'old_class_pins':old_plan['observer_classes']})
assert len(carried)==10
old_classes={Path(c['path']).name:c for c in old_plan['observer_classes']}
new_classes={Path(c['path']).name:c for c in new_plan['observer_classes']}
for row in list(old_classes.values())+list(new_classes.values()):assert sha(Path(row['path'])).upper()==row['sha256'].upper()
changed=[name for name in old_classes if old_classes[name]['sha256']!=new_classes[name]['sha256']]
assert changed==['PublicServiceHarness.class'],changed
proof={'schema_version':1,'kind':'EXACT_OWN_NULL_OBSERVER_REPAIR_SOURCE_AWARE_TEN_CASE_CARRY',
 'old_source':{'path':str(old_source),'sha256':sha(old_source)},'new_source':{'path':str(new_source),'sha256':sha(new_source)},
 'exact_only_declared_replacement':True,'source_diff':list(difflib.unified_diff(old.splitlines(),new.splitlines())),
 'unchanged_compiled_classes':[name for name in old_classes if name not in changed],'changed_compiled_classes':changed,
 'cases':carried,'limits':['Original business class and runtime are unchanged; this is own observer repair only',
 'Carried records retain old adapter/native identities, never relabeled as new binary execution',
 'Failed old all-filtered case is not carried as completed evidence; fresh corrected run required',
 'No typed value fabricated or raw observation rewritten']}
path=base/'corpus02/ten-case-carry.json'
with path.open('x',encoding='utf-8')as f:json.dump(proof,f,indent=2);f.write('\n')
print(json.dumps({'sha256':sha(path),'carried_cases':len(carried),'changed_compiled_classes':changed}))
