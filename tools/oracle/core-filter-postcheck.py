"""Read-only binding of old canonical inputs and frozen new public observer sources."""
import hashlib
import json
from pathlib import Path

workspace=Path(__file__).resolve().parents[2]
owned=workspace/'.local/sprint18/service'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path):return json.loads(path.read_text(encoding='utf-8-sig'))
old=workspace/'.local/sprint16/service'
proof=old/'canonical-build-proof02.json'
assert sha(proof)=='976db2b8712233abd6323286e0ad0ad0b0198d74147fc35596a18f13a8bedd83'
runtime=read(proof)['runtime_files']
for row in runtime:
    path=Path(row['path']);assert path.stat().st_size==row['bytes'] and sha(path)==row['sha256'].lower()
tree_path=workspace/'.local/sprint06/reference/build-cold04/provenance/tree.json'
assert sha(tree_path)=='bce30c8d971da259d4947f7ae9db904765dc1e980f5b9d41ccd86567a45fd96f'
tree=read(tree_path);source=old/'bootstrap02/source';count=0;total=0
for row in tree['tree']:
    if row['type']!='blob':continue
    data=(source/row['path']).read_bytes()
    assert len(data)==row['size']
    assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==row['sha']
    count+=1;total+=len(data)
assert count==5763 and len(runtime)==285
public=sorted((workspace/'tools/oracle').glob('core-filter-*'))
fixtures=sorted(p for p in (workspace/'fixtures/oracle-core-filter').rglob('*') if p.is_file())
inventory=[{'path':str(p.relative_to(workspace)).replace('\\','/'),'bytes':p.stat().st_size,'sha256':sha(p)} for p in public+fixtures]
result={'schema_version':1,'status':'READ_ONLY_POSTCHECK_CANONICAL_INPUTS_AND_NEW_PUBLIC_SOURCE_FREEZE',
 'original_source_blobs':count,'original_source_bytes':total,'runtime_files':len(runtime),
 'canonical_build_proof_sha256':sha(proof),'tree_sha256':sha(tree_path),
 'old_source_tree_modified':False,'old_runtime_modified':False,
 'public_source_inventory':inventory,'limits':['No Gradle/build/cache/source mutation',
 'Per-file readback is not an atomic filesystem snapshot','Frozen8 case manifest retained exactly']}
path=owned/'r5-filter01/postcheck.json'
with path.open('x',encoding='utf-8')as target:json.dump(result,target,indent=2);target.write('\n')
print(json.dumps({'sha256':sha(path),'source_files':count,'runtime_files':len(runtime),'public_files':len(inventory)}))
