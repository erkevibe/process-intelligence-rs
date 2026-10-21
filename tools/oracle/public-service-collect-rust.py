"""Validate closed retained native captures; copy JSON bytes without numeric rewriting."""
import argparse
import hashlib
import json
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--plan',type=Path,required=True)
parser.add_argument('--out',type=Path,required=True)
args=parser.parse_args()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
plan=read(args.plan);rows=[]
for case in plan['cases']:
    config_path=Path(case['config']);assert sha(config_path).upper()==case['config_sha256'].upper()
    directory=Path(case['capture_directory']);records=[]
    for label,name in [('worker','worker.process.json'),('child','child.process.json')]:
        record=read(directory/name)
        assert record['native_exit']==0 and record['stdout_complete'] and record['stderr_complete']
        assert not record['output_limit'] and not record['capture_fault'] and not record['drain_timeout']
        for stream in ['stdout','stderr']:
            path=directory/(label+'.'+stream)
            assert sha(path).upper()==record[stream+'_sha256'].upper()
            assert path.stat().st_size==record[stream+'_bytes_persisted']
        records.append({'path':str(directory/name),'sha256':sha(directory/name)})
    raw=directory/'child.stdout';observed=read(raw)
    assert observed['input_sha256'].lower()==case['input_sha256'].lower()
    copied=args.plan.parent/(case['id']+'.json')
    with copied.open('xb')as target:target.write(raw.read_bytes())
    assert sha(copied)==sha(raw)
    rows.append({'id':case['id'],'input_sha256':case['input_sha256'],'path':str(copied),
                 'observation_sha256':sha(copied),'native':{'path':str(directory),'records':records},
                 'program_sha256':case['reused_program_sha256'],'preview_status':observed['preview']['status']})
result={'schema_version':1,'status':'ACTUAL_RETAINED_RUST_NATIVE_OBSERVATIONS_CAPTURED',
        'case_count':len(rows),'plan_sha256':sha(args.plan),'collector_source_sha256':sha(Path(__file__)),
        'json_bytes_copied_without_reencoding':True,'cases':rows,
        'limits':['Retained exact observer executable; no new product build or deployment',
                  'Native stderr preserved even on success','Raw metadata and preview admission are separate profiles']}
with args.out.open('x',encoding='utf-8')as target:json.dump(result,target,indent=2);target.write('\n')
print(json.dumps({'cases':len(rows),'sha256':sha(args.out)}))
