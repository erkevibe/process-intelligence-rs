"""Path-only public projection of captured S20 evidence; no native/engine calls.

Number lexemes and scientific strings are preserved. Native capture digests
continue to describe preserved *.raw.stdout/stderr, never projected protocol.
The manifest explicitly inventories omissions and both file identities.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import os
import time

ROOT=Path(__file__).resolve().parents[2]
PROFILE=Path.home()
ABSOLUTE=re.compile(r'(?i)(?<![a-z0-9])(?:file:/+)?[a-z]:[\\/]|/(?:Users|home)/')
RULES={
 'path_fields':['**/program','**/classes','**/origin_path','**/code_source','**/java_sources/*/path','**/native_counter_calibrations/*/file'],
 'jvm_properties':['user.home','java.io.tmpdir','java.util.prefs.userRoot','java.util.prefs.systemRoot','logback.configurationFile'],
 'forbidden_science_ancestors':['input_xlog_before','input_xlog_after','graph','exception','events','attributes','traces'],
 'omissions':['provenance/**','*-negative-controls/**','**/checkpoint-*.json','**/*.args',
              'conversion-audit/* except independent-audit.json',
              'miner-audit/* except independent-audit.json and independent-audit-semantics/**','README.md'],
 'descriptor_rebinding':'Only {file,sha256,bytes} objects matching included original file identity; index environment_sha256/hardware_sha256. Original capture hashes and original build/runtime/class pins remain original.',
 'opaque_scientific_bytes':['conversions/inputs/**','conversion-boundaries/inputs/**',
                            'conversions/cases/<id>/(forward|inverse)/payload.json',
                            'conversion-boundaries/cases/<id>/payload.json']}


class Number(str):
    pass


def require(value,reason):
    if not value:raise ValueError(reason)


def sha(raw):return hashlib.sha256(raw).hexdigest()


def parse(raw):
    def unique(pairs):
        result={}
        for k,v in pairs:
            require(k not in result,'duplicate_json_key');result[k]=v
        return result
    return json.loads(raw.decode('utf-8',errors='strict'),parse_int=Number,parse_float=Number,
                      parse_constant=lambda x: (_ for _ in ()).throw(ValueError('nonfinite_json')),object_pairs_hook=unique)


def emit(value):
    if isinstance(value,Number):return str(value)
    if value is None:return 'null'
    if value is True:return 'true'
    if value is False:return 'false'
    if isinstance(value,int):return str(value)
    if isinstance(value,str):return json.dumps(value,ensure_ascii=False)
    if isinstance(value,list):return '['+','.join(emit(v) for v in value)+']'
    if isinstance(value,dict):return '{'+','.join(json.dumps(k,ensure_ascii=False)+':'+emit(v) for k,v in value.items())+'}'
    raise ValueError('unhandled_json_value')


def numeric_tokens(value,skip_descriptor_bytes=False):
    result=[]
    def walk(v):
        if isinstance(v,Number):result.append(str(v))
        elif isinstance(v,int) and not isinstance(v,bool):result.append(str(v))
        elif isinstance(v,list):
            for item in v:walk(item)
        elif isinstance(v,dict):
            for k,item in v.items():
                if skip_descriptor_bytes and k=='bytes' and {'file','sha256','bytes'}<=set(v):continue
                walk(item)
    walk(value)
    return sha(('\n'.join(result)).encode('ascii'))


def alias(text):
    # Prefix aliases only, never a regex substitution within scientific text.
    for base,name in ((ROOT,'workspace:/'),(PROFILE,'userprofile:/')):
        for prefix in (str(base),base.as_posix(),'file:/'+base.as_posix(),'file:///'+base.as_posix()):
            if text[:len(prefix)].casefold()==prefix.casefold():
                suffix=text[len(prefix):]
                require(not suffix or suffix[0] in '/\\','path_prefix_boundary')
                return name+suffix.lstrip('/\\').replace('\\','/')
    raise ValueError('unknown_absolute_path_alias')


def project_strings(value,pointer=(),changes=None):
    changes=[] if changes is None else changes
    if isinstance(value,Number):return value
    if isinstance(value,str):
        if not ABSOLUTE.search(value):return value
        key=pointer[-1] if pointer else ''
        require(not any(p in RULES['forbidden_science_ancestors'] for p in pointer),'path_in_scientific_string')
        allowed=key in ('program','classes','origin_path','code_source')
        allowed=allowed or key=='path' and 'java_sources' in pointer
        allowed=allowed or key=='file' and 'native_counter_calibrations' in pointer
        if 'jvm_arguments' in pointer:
            require(value.startswith('-D') and '=' in value,'unrecognized_path_jvm_argument')
            prop,payload=value[2:].split('=',1)
            require(prop in RULES['jvm_properties'],'unrecognized_path_jvm_property')
            projected='-D'+prop+'='+alias(payload)
        else:
            require(allowed,'unknown_path_field:'+ '/'.join(pointer))
            projected=alias(value)
        require(not ABSOLUTE.search(projected),'unaliased_absolute_path')
        changes.append({'pointer':'/'+ '/'.join(pointer),'kind':'path_alias'})
        return projected
    if isinstance(value,list):return [project_strings(v,pointer+(str(i),),changes) for i,v in enumerate(value)]
    if isinstance(value,dict):return {k:project_strings(v,pointer+(k,),changes) for k,v in value.items()}
    return value


def include(relative):
    parts=relative.parts
    if not parts:return False
    if parts[0] not in ('conversions','conversion-boundaries','miner-performance','conversion-audit','miner-audit'):return False
    if relative.name.startswith('checkpoint-') or relative.suffix=='.args':return False
    if parts[0]=='conversion-audit':return relative.name=='independent-audit.json'
    if parts[0]=='miner-audit':return relative.name=='independent-audit.json' or len(parts)>1 and parts[1]=='independent-audit-semantics'
    return True


def opaque_scientific_path(name):
    parts=Path(name).as_posix().split('/')
    if len(parts)>=3 and parts[0] in ('conversions','conversion-boundaries') and parts[1]=='inputs':return True
    return re.fullmatch(r'conversions/cases/[^/]+/(forward|inverse)/payload\.json|conversion-boundaries/cases/[^/]+/payload\.json',name) is not None


def no_reparse(path):
    info=path.lstat()
    require(not (getattr(info,'st_file_attributes',0)&1024),'reparse_path')
    require(not path.is_symlink(),'reparse_path')
    return info


def parent_chain(path):
    for item in reversed((path,)+tuple(path.parents)):
        if item.exists() or item.is_symlink():no_reparse(item)


def bounded(path):
    no_reparse(path)
    require(path.is_file(),'regular_file_required')
    with path.open('rb') as stream:raw=stream.read(32*1024*1024+1)
    require(len(raw)<=32*1024*1024,'file_cap')
    return raw


def enumerate_files(source,deadline):
    pending=[source];count=0
    while pending:
        directory=pending.pop();no_reparse(directory)
        with os.scandir(directory) as entries:
            batch=[]
            for entry in entries:
                require(time.monotonic()<=deadline,'enumeration_deadline')
                count+=1;require(count<=20000,'enumeration_entry_cap')
                path=Path(entry.path);no_reparse(path);batch.append(path)
        for path in sorted(batch):
            if path.is_dir():pending.append(path)
            else:
                require(path.is_file(),'unsupported_source_entry')
                yield path


def descriptor_updates(value,lookup,changes,pointer=()):
    if isinstance(value,dict):
        if {'file','sha256','bytes'}<=set(value) and isinstance(value['file'],str) and isinstance(value['sha256'],str):
            key=(value['file'],value['sha256'].lower(),int(value['bytes']))
            if key in lookup:
                digest,length=lookup[key]
                if digest!=value['sha256'].lower() or length!=int(value['bytes']):
                    value['sha256']=digest;value['bytes']=Number(str(length))
                    changes.append({'pointer':'/'+ '/'.join(pointer),'kind':'artifact_descriptor_rebound'})
        for k,v in value.items():descriptor_updates(v,lookup,changes,pointer+(k,))
    elif isinstance(value,list):
        for i,v in enumerate(value):descriptor_updates(v,lookup,changes,pointer+(str(i),))


def generate(source,output):
    parent_chain(source);parent_chain(output.parent)
    no_reparse(source)
    require(source.is_dir() and not output.exists() and not output.is_symlink(),'fresh_output_required')
    require(not output.resolve().is_relative_to(source.resolve()),'output_outside_source')
    files={};omissions=[];total=0
    deadline=time.monotonic()+180
    for path in enumerate_files(source,deadline):
        relative=path.relative_to(source);raw=bounded(path);total+=len(raw)
        require(total<=512*1024*1024,'aggregate_source_cap')
        name=relative.as_posix()
        if not include(relative):
            omissions.append({'path':name,'sha256':sha(raw),'bytes':len(raw),'reason':'declared_ancillary_selection_rule'})
            continue
        changes=[];value=None;opaque=opaque_scientific_path(name)
        if opaque:
            # Deliberately malformed JSON and duplicate keys are scientific
            # rejection inputs, not metadata to parse, repair or normalize.
            pass
        elif path.suffix=='.json':
            value=project_strings(parse(raw),changes=changes)
        elif path.suffix in ('.stdout','.stderr'):
            # Full raw stream publication is allowed only when path-free.
            require(not ABSOLUTE.search(raw.decode('utf-8',errors='strict')),'private_path_in_raw_capture:'+name)
        elif re.search(br'(?i)(?<![a-z0-9])[a-z]:[\\/]|/(?:Users|home)/',raw):
            # XML/CSV/XES scientific content must remain byte-identical.
            raise ValueError('private_path_in_unprojectable_artifact:'+name)
        files[name]={'raw':raw,'value':value,'changes':changes,'published':raw,'opaque':opaque}
    require('miner-performance/index.json' in files,'benchmark_index_required')
    # Rebind the finite acyclic artifact chain. Rebuild from original projected
    # metadata each pass so old descriptor keys remain resolvable.
    originals={name:project_strings(parse(row['raw']),changes=[]) for name,row in files.items() if row['value'] is not None}
    for iteration in range(12):
        require(time.monotonic()<=deadline,'projection_deadline')
        lookup={}
        for name,row in files.items():
            key=(Path(name).name,sha(row['raw']),len(row['raw']))
            target=(sha(row['published']),len(row['published']))
            require(key not in lookup or lookup[key]==target,'ambiguous_descriptor_projection')
            lookup[key]=target
        stable=True
        for name,row in files.items():
            changes=[x for x in row['changes'] if x['kind']=='path_alias']
            if name in originals:
                value=parse(emit(originals[name]).encode('utf-8'))
                descriptor_updates(value,lookup,changes)
                if name=='miner-performance/index.json':
                    for key,pathkey in (('environment_sha256','environment_path'),('hardware_sha256','hardware_path')):
                        target=files['miner-performance/'+value[pathkey]]['published']
                        if value[key].lower()!=sha(target):
                            value[key]=sha(target);changes.append({'pointer':'/'+key,'kind':'index_metadata_descriptor_rebound'})
                candidate=(emit(value)+'\n').encode('utf-8') if changes else row['raw']
                row['value']=value
            elif name.endswith('/capture/benchmark.stdout'):
                lines=[]
                for line in row['raw'].splitlines(keepends=True):
                    if line.startswith(b'S20_PROTOCOL '):
                        record=parse(line[13:])
                        if record.get('phase')=='TERMINAL_READY':
                            descriptor_updates(record,lookup,changes)
                            ending=b'\r\n' if line.endswith(b'\r\n') else b'\n' if line.endswith(b'\n') else b''
                            line=b'S20_PROTOCOL '+emit(record).encode('utf-8')+ending
                    lines.append(line)
                candidate=b''.join(lines)
                if candidate!=row['raw']:changes.append({'pointer':'protocol-only','kind':'projected_protocol_not_raw_capture'})
            else:candidate=row['raw']
            if candidate!=row['published']:stable=False
            row['published']=candidate;row['changes']=changes
        if stable:break
    else:raise ValueError('descriptor_chain_not_converged')
    # Sidecars preserve exact original captures; process records retain their
    # original stdout/stderr byte counts and hashes, without relabelling them.
    extras={}
    for name,row in files.items():
        if name.endswith('/capture/benchmark.stdout') or name.endswith('/capture/benchmark.stderr'):
            suffix=name.rsplit('.',1)[1];rawname=name.rsplit('.',1)[0]+'.raw.'+suffix
            extras[rawname]={'raw':row['raw'],'published':row['raw'],'changes':[], 'source':name,'preserved_original_capture':True}
    files.update(extras)
    output.mkdir()
    inventory=[]
    for name,row in sorted(files.items()):
        require(time.monotonic()<=deadline,'publication_deadline')
        destination=output/name;destination.parent.mkdir(parents=True,exist_ok=True)
        parent_chain(destination.parent)
        with destination.open('xb') as stream:stream.write(row['published'])
        entry={'path':name,'source_path':row.get('source',name),'original_sha256':sha(row['raw']),
               'original_bytes':len(row['raw']),'published_sha256':sha(row['published']),
               'published_bytes':len(row['published']),'transformations':row['changes'],
               'preserved_original_capture':row.get('preserved_original_capture',False)}
        if row.get('opaque'):
            require(row['published']==row['raw'] and not row['changes'],'opaque_scientific_bytes_changed')
            entry['representation']='opaque_scientific_bytes'
        elif name.endswith('.json'):
            original=parse(row['raw']);published=parse(row['published'])
            old=numeric_tokens(original,True);new=numeric_tokens(published,True)
            require(old==new,'scientific_numeric_lexemes_changed:'+name)
            entry['scientific_numeric_lexeme_sha256']=old
            entry['numeric_exclusion']='bytes only inside explicit file/sha256/bytes descriptors; descriptor changes individually inventoried'
        inventory.append(entry)
    manifest={'schema_version':1,'status':'EXPLICIT_PATH_ONLY_PUBLIC_PROJECTION',
              'aliases':{'workspace:/':'original workspace root','userprofile:/':'original user profile root'},
              'rules':RULES,'files':inventory,'omissions':omissions,'manifest_excludes_itself':True,
              'raw_capture_authority':'benchmark.raw.stdout/raw.stderr are byte-exact originals; original native record counts/hash describe them. benchmark.stdout is separately hash-bound projected protocol, never raw.',
              'original_class_runtime_jdk_pins_unchanged':True,'no_new_native_or_engine_execution':True}
    with (output/'public-projection.json').open('x',encoding='utf-8',newline='\n') as stream:
        stream.write(emit(manifest)+'\n')
    return manifest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();manifest=generate(args.source,args.output)
    print(json.dumps({'files':len(manifest['files']),'omissions':len(manifest['omissions']),
                      'manifest_sha256':sha(bounded(args.output/'public-projection.json'))}))


if __name__=='__main__':main()
