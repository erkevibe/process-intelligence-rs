"""Independent S22 logical projection manifest/hash/numeric/selected-alias verification."""
import argparse,hashlib,importlib.util,json,os,re,time
from pathlib import Path,PurePosixPath
ap=argparse.ArgumentParser();ap.add_argument('logical',type=Path);ap.add_argument('output',type=Path);ap.add_argument('--policy',type=Path,required=True);ap.add_argument('--policy-sha',required=True);ap.add_argument('--selection-sha',required=True);ap.add_argument('--workspace',type=Path);ap.add_argument('--bundle-kind',choices=['primary','process'],default='primary');a=ap.parse_args()
start=time.monotonic();root=a.logical.absolute();workspace=a.workspace.absolute() if a.workspace else None
class N(str):pass
def need(ok,why):
    if not ok:raise ValueError(why)
def bound():need(time.monotonic()-start<90,'audit90s')
def sha(b):return hashlib.sha256(b).hexdigest()
def pairs(rows):
    d={}
    for k,v in rows:need(k not in d,'duplicate_json');d[k]=v
    return d
def parse(b):return json.loads(b,parse_int=N,parse_float=N,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite')))
def relative(s):
    need(type(s) is str and s and not PurePosixPath(s).is_absolute() and '\\' not in s and ':' not in s,'relative_path')
    need(all(p and p not in ['.','..'] and not p.endswith(('.',' ')) for p in s.split('/')),'unambiguous_path');return s
def safe(path,anchor):
    q=path.absolute();need(q.is_relative_to(anchor),'boundary')
    while True:
        need(not q.is_symlink() and not(getattr(q.lstat(),'st_file_attributes',0)&1024),'no_reparse')
        if q==anchor:break
        q=q.parent

def read(path,anchor,cap=32*1024*1024):
    bound();safe(path,anchor);need(path.is_file() and path.stat().st_size<=cap,'bounded_file')
    with path.open('rb') as f:b=f.read(cap+1)
    need(len(b)<=cap,'read_cap');return b

def nums(value):
    result=[]
    def walk(x):
        if type(x) is N:result.append(str(x))
        elif isinstance(x,dict):
            for y in x.values():walk(y)
        elif isinstance(x,list):
            for y in x:walk(y)
    walk(value);return sha('\n'.join(result).encode('ascii'))
def alias(value):
    for base,label in [(workspace,'workspace:/'),(Path.home().absolute(),'userprofile:/')]:
        for prefix in sorted({str(base),base.as_posix(),'file:/'+base.as_posix(),'file:///'+base.as_posix()},key=len,reverse=True):
            if value[:len(prefix)].casefold()==prefix.casefold():
                tail=value[len(prefix):];need(not tail or tail[0] in '/\\','alias_boundary');need(all(p not in ['.','..'] for p in tail.replace('\\','/').split('/')),'alias_dot')
                return label+tail.lstrip('/\\').replace('\\','/')
    raise ValueError('unknown_original_path_alias')
def pointer(k):return str(k).replace('~','~0').replace('/','~1')
def diff(original,public,entry,path=''):
    paths=set(entry.get('json_pointers',[]));uris=set(entry.get('uri_pointers',[]));guards=set(entry.get('guard_message_pointers',[]))
    if path in paths:need(type(original) is str and public==alias(original),'exact_selected_alias');return
    if path in uris:need(type(original) is str and original==public,'uri_byte_value_unchanged');policy.relative_uri(public,public_workspace,public_profile);return
    if path in guards:
        target='workspace:/.local/sprint21/root/sprint22/controls04/own-05/guard-denial.bin'
        need(path=='/guard_failure/message' and public=="The process cannot access the file '"+target+"' because it is being used by another process.",'exact_guard_message_alias');return
    need(type(original) is type(public),'nonselected_type_unchanged')
    if isinstance(original,dict):
        need(list(original)==list(public),'nonselected_keys_order_unchanged')
        for key in original:diff(original[key],public[key],entry,path+'/'+pointer(key))
    elif isinstance(original,list):
        need(len(original)==len(public),'array_length')
        for i,x in enumerate(original):diff(x,public[i],entry,path+'/'+str(i))
    else:need(original==public,'nonselected_value_unchanged')
def public_leaves(value,entry,path='',used=None):
    if used is None:used=set()
    paths=set(entry.get('json_pointers',[]));uris=set(entry.get('uri_pointers',[]));guards=set(entry.get('guard_message_pointers',[]))
    if type(value) is str:
        if path in paths:
            need(value.startswith(('workspace:/','userprofile:/')),'selected_path_is_alias');tail=value.split(':/',1)[1];need(not tail.startswith('/') and '\\' not in tail and all(x not in ['.','..'] for x in tail.split('/')),'alias_no_escape');used.add(path)
        elif path in uris:policy.relative_uri(value,public_workspace,public_profile);used.add(path)
        elif path in guards:
            target='workspace:/.local/sprint21/root/sprint22/controls04/own-05/guard-denial.bin';need(path=='/guard_failure/message' and value=="The process cannot access the file '"+target+"' because it is being used by another process.",'exact_public_guard_message');used.add(path)
        else:need(not policy.ABSOLUTE.search(value),'unselected_absolute_path')
    elif isinstance(value,dict):
        for k,v in value.items():public_leaves(v,entry,path+'/'+pointer(k),used)
    elif isinstance(value,list):
        for i,v in enumerate(value):public_leaves(v,entry,path+'/'+str(i),used)
    if path=='':need(used==paths|uris|guards,'all_explicit_pointers_used')
need(not a.output.exists(),'fresh_output');policy_bytes=a.policy.read_bytes();need(sha(policy_bytes).upper()==a.policy_sha,'exact_policy_pin')
spec=importlib.util.spec_from_file_location('reviewed_privacy_policy',a.policy);policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
public_workspace=workspace if workspace else root;public_profile=Path.home().absolute()
manifest=load_manifest=parse(read(root/'projection-manifest.json',root,4*1024*1024))
need(manifest['manifest_sha256'].upper()==a.selection_sha and type(manifest['schema_version']) is N and manifest['schema_version']=='1','exact_projection_selection_binding')
need(len(manifest['entries'])==(349 if a.bundle_kind=='primary' else 27),'exact_frozen_entry_count')
expected={'projection-manifest.json'};folded=set();sourcefold=set();original_total=public_total=0;omitted=[];projected=[];byte_count=0
for entry in manifest['entries']:
    bound();name=relative(entry['public_path']);need(name.casefold() not in folded,'public_collision');folded.add(name.casefold())
    source=entry['source'];need(type(source) is str and source.startswith('workspace:/'),'source_alias');src=relative(source[len('workspace:/'):]);need(src.casefold() not in sourcefold,'source_collision');sourcefold.add(src.casefold())
    original_total+=int(entry['original_bytes']);original=None
    if workspace:
        original=read(workspace/src,workspace);need(len(original)==int(entry['original_bytes']) and sha(original)==entry['original_sha256'].lower(),'actual_private_source_pin')
    if entry['mode']=='omit':
        need(entry['public_sha256'] is None and int(entry['public_bytes'])==0 and not(root/name).exists() and entry.get('reason'),'explicit_omit')
        omitted.append(name);continue
    expected.add(name);raw=read(root/name,root);public_total+=len(raw)
    need(len(raw)==int(entry['public_bytes']) and sha(raw)==entry['public_sha256'].lower(),'actual_public_bytes_sha')
    nd=entry.get('memory_ndjson',False);value=None
    if entry['mode']=='bytes':
        need(entry['original_sha256'].lower()==sha(raw) and int(entry['original_bytes'])==len(raw),'all_byte_mode_exact_original')
        if original is not None:need(raw==original,'scientific_native_bytes_exact')
        if nd:
            policy.validate_memory_ndjson(raw,src,name,public_workspace,public_profile);value=[parse(line) for line in raw.splitlines()]
        elif raw.lstrip().startswith((b'{',b'[')):
            value=parse(raw)
        if value is not None and entry.get('uri_pointers'):
            need(not nd,'ndjson_uri_pointer_mode');public_leaves(value,entry)
        byte_count+=1
    else:
        need(entry['mode']=='json_paths','known_projection_mode');value=parse(raw);public_leaves(value,entry)
        if original is not None:
            old=parse(original)
            if entry.get('guard_message_pointers'):
                guard=old['guard_failure'];target=str(workspace/'.local/sprint21/root/sprint22/controls04/own-05/guard-denial.bin')
                need(guard['target']==target and guard['type']=='System.IO.IOException' and type(guard['hresult']) is N and guard['hresult']=='-2147024864' and guard['expected_owned_sharing_failure'] is True and guard['message']=="The process cannot access the file '"+target+"' because it is being used by another process.",'actual_original_guard_typed_template')
            diff(old,value,entry)
        projected.append(name)
    if value is not None:
        actual=nums(value);need(entry['numeric_tokens_sha256_before']==entry['numeric_tokens_sha256_after']==actual,'original_numeric_lexemes_bound')
    else:need(entry['numeric_tokens_sha256_before'] is None and entry['numeric_tokens_sha256_after'] is None,'nonjson_numeric_fields_null')
    policy.machine_leak(raw,public_workspace,public_profile,ndjson=nd)
need(original_total==int(manifest['source_bytes']) and public_total==int(manifest['public_bytes']),'all_manifest_totals')
actual=set();nodes=0;pending=[root]
while pending:
    parent=pending.pop();safe(parent,root)
    with os.scandir(parent) as items:
        for item in items:
            bound();nodes+=1;need(nodes<=2000,'finite_tree_nodes');p=Path(item.path);safe(p,root)
            if item.is_dir(follow_symlinks=False):pending.append(p)
            else:need(item.is_file(follow_symlinks=False),'regular_public_file');actual.add(p.relative_to(root).as_posix())
need(actual==expected,'exact_public_logical_fileset')
need(set(omitted)==({'measurement/private-credentials.json','measurement/http-10k/private-setup-request.json'} if a.bundle_kind=='primary' else set()),'only_declared_private_omissions')
if a.bundle_kind=='primary':need('measurement/session/cluster-identity.stdout' in projected,'cluster_projection_declared')
# Native capture descriptors keep original hashes even when a representation is explicitly path-projected.
entries={e['public_path']:e for e in manifest['entries']}
for name in actual:
    if not name.endswith('.process.json'):continue
    record=parse(read(root/name,root));stem=name[:-len('.process.json')]
    for side in ['stdout','stderr']:
        if record.get(side+'_sha256') is None:continue
        need(stem+'.'+side in entries or a.bundle_kind=='process','raw_native_entry_required_primary')
        if stem+'.'+side not in entries:continue
        e=entries[stem+'.'+side]
        need(record[side+'_sha256'].lower()==e['original_sha256'].lower() and int(record[side+'_bytes_persisted'])==int(e['original_bytes']),'native_original_descriptor_never_rebound')
bound()
with a.output.open('x',encoding='utf-8') as f:json.dump({'status':'INDEPENDENT_LOGICAL_PUBLIC_PROJECTION_HASH_NUMERIC_ALIAS_POLICY_VERIFIED','policy_sha256':a.policy_sha,'selection_sha256':a.selection_sha,'projection_manifest_sha256':sha(read(root/'projection-manifest.json',root,4*1024*1024)).upper(),'entries':len(manifest['entries']),'byteexact_original_files':byte_count,'projected_files':len(projected),'private_omissions':omitted,'all_logical_files':len(actual),'actual_private_original_bytes_checked':workspace is not None,'native_raw_descriptor_entries_checked':a.bundle_kind=='primary','all_private_original_fields_compared':workspace is not None,'bundle_kind':a.bundle_kind,'scope':'Private mode checks every actual original and independent selected-pointer diff; public mode checks fixed manifest/hash/numeric/policy chain without claiming inaccessible private originals were reread. No child/native/PG/network execution.'},f,indent=2)