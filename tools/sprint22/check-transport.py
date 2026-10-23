"""Independent finite synthetic transport roundtrip and adversarial controls; no child/network."""
import argparse,copy,gzip,hashlib,importlib.util,json,time,zlib
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('workspace',type=Path);p.add_argument('fixture_root',type=Path);p.add_argument('output',type=Path);p.add_argument('--transport-sha',required=True);p.add_argument('--policy-sha',required=True);a=p.parse_args()
start=time.monotonic();workspace=a.workspace.absolute();fixture=a.fixture_root.absolute();results=[]
def need(ok,why):
    if not ok:raise ValueError(why)
def bound():need(time.monotonic()-start<60,'control60s')
def sha(b):return hashlib.sha256(b).hexdigest().upper()
source=workspace/'tools/sprint22/evidence-transport.py';need(sha(source.read_bytes())==a.transport_sha,'exact_transport_source')
need(fixture.is_relative_to(workspace/'.local/sprint21/root/sprint22') and not fixture.exists() and not a.output.exists(),'fresh_private_fixture')
spec=importlib.util.spec_from_file_location('reviewed_transport',source);t=importlib.util.module_from_spec(spec);spec.loader.exec_module(t)
need(t.POLICY==a.policy_sha and t.MAX_FILE==32*1024*1024 and t.MAX_TOTAL==64*1024*1024 and t.MAX_FILES==1000,'accepted_finite_policy')
fixture.mkdir();logical=fixture/'logical';logical.mkdir()
paths=sorted(t.LARGE);need(len(paths)==8,'eight_fixed_large_paths')
raws={name:bytes([65+i])*(256*1024) for i,name in enumerate(paths)};raws['native.stdout']=b'ORIGINAL-NATIVE\r\n'
rows=[{'public_path':n,'mode':'bytes','public_bytes':len(b),'public_sha256':sha(b)} for n,b in raws.items()]
raws['projection-manifest.json']=json.dumps({'schema_version':1,'entries':rows}).encode()
for name,b in raws.items():
    f=logical/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(b)
encoded=fixture/'encoded';encoded2=fixture/'encoded2';decoded=fixture/'decoded'
t.transport('encode',logical,encoded,workspace);t.transport('encode',logical,encoded2,workspace);t.transport('decode',encoded,decoded,workspace)
for name,b in raws.items():need((decoded/name).read_bytes()==b,'independent_all_logical_roundtrip')
base={f.relative_to(encoded).as_posix():f.read_bytes() for f in encoded.rglob('*') if f.is_file()}
need(base=={f.relative_to(encoded2).as_posix():f.read_bytes() for f in encoded2.rglob('*') if f.is_file()},'deterministic_transport_bytes')
m=json.loads(base[t.MANIFEST]);need(sum(e['encoding']=='gzip' for e in m['entries'])==8,'all_eight_whitelisted_gzip')
for e in m['entries']:
    need(e['projected_sha256']==sha(raws[e['logical_path']]),'projected_hash_not_rebound')
    if e['encoding']=='gzip':
        b=base[e['stored_path']];need(b[:3]==b'\x1f\x8b\x08' and b[3]==0 and b[4:8]==b'\0'*4,'no_filename_mtime0')
need((decoded/'native.stdout').read_bytes()==raws['native.stdout'],'native_original_bytes')
results.append('all8_roundtrip_deterministic_nativehash_preserved')
def rejects(name,call):
    bound()
    try:call()
    except (ValueError,zlib.error,gzip.BadGzipFile):results.append(name)
    else:raise ValueError('negative_accepted_'+name)
for value in ['../escape','/absolute','C:/drive','a\\b','a:stream','a/./b','a//b','a./b','a /b','CON','nul.txt']:
    rejects('traversal_'+str(len(results)),lambda v=value:t.relative(v))
rejects('casefold_collision',lambda:t.tree_names(['A','a']))
rejects('file_directory_collision',lambda:t.tree_names(['inputs/CMP10K.xes','inputs/CMP10K.xes/child']))
compressed=gzip.compress(b'A'*4096,mtime=0)
rejects('decoded_size_mismatch',lambda:t.inflate(compressed,4095))
rejects('truncated_gzip',lambda:t.inflate(compressed[:-1],4096))
rejects('concat_gzip',lambda:t.inflate(compressed+gzip.compress(b'B',mtime=0),4096))
rejects('trailing_gzip',lambda:t.inflate(compressed+b'EXTRA',4096))
corrupt=bytearray(compressed);corrupt[-8]^=1
rejects('crc_corruption',lambda:t.inflate(bytes(corrupt),4096))
rejects('declared_file_bomb',lambda:t.inflate(compressed,32*1024*1024+1))
bomb=gzip.compress(b'Z'*(32*1024*1024+1),mtime=0)
rejects('actual_inflate_bomb_bounded',lambda:t.inflate(bomb,1))
def mutated(name,change):
    files=dict(base);manifest=copy.deepcopy(m);change(manifest,files)
    files[t.MANIFEST]=json.dumps(manifest).encode();src=fixture/('bad-'+name);dst=fixture/('out-'+name);src.mkdir()
    for n,b in files.items():
        f=src/n;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(b)
    rejects(name,lambda:t.transport('decode',src,dst,workspace));need(not dst.exists(),'refused_before_output_'+name)
def first_gzip(man):return next(e for e in man['entries'] if e['encoding']=='gzip')
mutated('stored_hash_corruption',lambda man,files:files.__setitem__(first_gzip(man)['stored_path'],b'X'+files[first_gzip(man)['stored_path']][1:]))
mutated('projected_hash_corruption',lambda man,files:first_gzip(man).__setitem__('projected_sha256','0'*64))
mutated('descriptor_size_corruption',lambda man,files:first_gzip(man).__setitem__('projected_bytes',first_gzip(man)['projected_bytes']+1))
mutated('duplicate_logical',lambda man,files:man['entries'].append(copy.deepcopy(man['entries'][0])))
mutated('manifest_traversal',lambda man,files:man['entries'][0].__setitem__('logical_path','../escape'))
mutated('extra_stored_file',lambda man,files:files.__setitem__('unexpected.bin',b'X'))
mutated('bool_schema',lambda man,files:man.__setitem__('schema_version',True))
mutated('entry_extra_field',lambda man,files:man['entries'][0].__setitem__('ambiguous',True))
mutated('lowercase_hash',lambda man,files:man['entries'][0].__setitem__('projected_sha256',man['entries'][0]['projected_sha256'].lower()))
# Coherently repair transport SHA/length so concatenation/trailing reaches inflater.
def append_member(man,files,suffix):
    e=first_gzip(man);b=files[e['stored_path']]+suffix;files[e['stored_path']]=b;e['stored_bytes']=len(b);e['stored_sha256']=sha(b);man['stored_bytes']=sum(x['stored_bytes'] for x in man['entries'])
mutated('concat_coherent_descriptors',lambda man,files:append_member(man,files,gzip.compress(b'X',mtime=0)))
mutated('trailing_coherent_descriptors',lambda man,files:append_member(man,files,b'EXTRA'))
# Full decoder collision with coherent logical projection hashes; must reject before any write.
def prefix(man,files):
    e=next(e for e in man['entries'] if e['logical_path']=='native.stdout');old=e['stored_path'];new='inputs/CMP10K.xes/child.bin';files[new]=files.pop(old);e['logical_path']=new;e['stored_path']=new
    projection=json.loads(files['projection-manifest.json']);next(x for x in projection['entries'] if x['public_path']=='native.stdout')['public_path']=new
    b=json.dumps(projection).encode();files['projection-manifest.json']=b
    pm=next(x for x in man['entries'] if x['logical_path']=='projection-manifest.json');pm.update(projected_bytes=len(b),stored_bytes=len(b),projected_sha256=sha(b),stored_sha256=sha(b));man['projection_manifest_sha256']=sha(b);man['decoded_bytes']=sum(x['projected_bytes'] for x in man['entries']);man['stored_bytes']=sum(x['stored_bytes'] for x in man['entries'])
mutated('coherent_logical_prefix_collision',prefix)
bound()
with a.output.open('x',encoding='utf-8') as f:json.dump({'status':'INDEPENDENT_FINITE_SYNTHETIC_TRANSPORT_CONTROLS_PASS','transport_sha256':a.transport_sha,'policy_sha256':a.policy_sha,'controls':results,'controls_count':len(results),'all_eight_whitelist_roundtrips':True,'native_descriptors_rebound':False,'scope':'Synthetic byte fixtures only; no claim actual scientific corpus accepted by these controls; no child/network execution.'},f,indent=2)