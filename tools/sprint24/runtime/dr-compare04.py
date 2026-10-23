"""Private saved DR comparator orchestration; Root executes after full captures."""
import argparse,hashlib,importlib.util,json,os
from pathlib import Path

def read(path,cap=2097152):
    assert not path.is_symlink()
    with path.open('rb') as stream: raw=stream.read(cap+1)
    assert len(raw)<=cap
    return raw

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--config',type=Path,required=True);ap.add_argument('--config-sha-file',type=Path,required=True);ap.add_argument('--pre',action='store_true');ap.add_argument('--cohort-only',action='store_true');a=ap.parse_args()
    raw=read(a.config,262144);assert hashlib.sha256(raw).hexdigest().upper()==read(a.config_sha_file,64).decode('ascii')
    c=json.loads(raw);out=Path(c['output']);tool=Path(c['comparator'])
    assert hashlib.sha256(read(tool,131072)).hexdigest().upper()==c['comparator_sha']
    spec=importlib.util.spec_from_file_location('reviewed_dr_compare',tool);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    expected_raw=read(Path(c['expected_proof']))
    assert hashlib.sha256(expected_raw).hexdigest().upper()==c['expected_proof_sha']
    expected=json.loads(expected_raw)
    def cohort(value):
        assert value['auth_users']==1 and value['auth_projects']==2 and value['sole_owners'] is True
        assert value['kv_keys']==['auth']
        assert {p['id'] for p in value['projects']}==set(c['expected_projects'])
        project=next(p for p in value['projects'] if p['id']==expected['project_id'])
        assert set(project['conversions'])=={'job-1','job-3','job-5'}
        for job in expected['jobs']:assert m.typed_equal(project['conversions'][job['id']],job['metadata'])
    if a.cohort_only:
        cohort(json.loads(read(out/'cohort-source.json',65536)))
        print(json.dumps({'status':'ACTUAL_SOURCE_COHORT_BOUND_BEFORE_DUMP'}));return
    before=m.load(out/'snapshot-source-before.json')
    for name in (('snapshot-source-after-dump.json','snapshot-target-before-app.json') if a.pre else ('snapshot-source-after-dump.json','snapshot-target-before-app.json','snapshot-source-final.json')):
        m.compare(before,m.load(out/name),False)
    if a.pre:
        print(json.dumps({'status':'ACTUAL_PRELOGIN_FULL_DATABASE_EQUAL'}));return
    after=m.load(out/'snapshot-target-after-login.json');m.compare(before,after,True)
    def nonauth(value):
        table=next(t for t in value['tables'] if t['name']=='pi_kv')
        return sorted((r for r in table['rows'] if r['key']!=['auth']),key=lambda r:r['key'])
    assert m.typed_equal(nonauth(before),nonauth(after)), 'non_auth_kv_changed'
    cohorts=[json.loads(read(out/name,65536)) for name in ('cohort-source.json','cohort-target-after.json')]
    expected=json.loads(read(Path(c['expected_proof'])))
    for value in cohorts:
        assert value['auth_users']==1 and value['auth_projects']==2 and value['sole_owners'] is True
        assert value['kv_keys']==['auth']
        project=next(p for p in value['projects'] if p['id']==expected['project_id'])
        assert set(project['conversions'])=={'job-1','job-3','job-5'}
        for job in expected['jobs']:assert m.typed_equal(project['conversions'][job['id']],job['metadata'])
    assert cohorts[0]['auth_stable_sha256']==cohorts[1]['auth_stable_sha256'], 'auth_non_session_state_changed'
    result={'status':'ACTUAL_CURRENT_COMPACT_DR_SNAPSHOT_PASS','all_five_tables_before_login_equal':True,'source_before_after_dump_final_equal':True,'postlogin_business_and_non_auth_kv_equal':True,'users_memberships_credentials_and_non_session_auth_equal':True,'owner_users':1,'projects':2,'completed_jobs':3,'limits':['Same PG18 jsonb binary encoding only.','No full schema certification, globals, cluster/PITR or restored RBAC matrix claim.']}
    with (out/'comparison-proof.json').open('xb') as f:f.write(json.dumps(result,indent=2).encode());f.flush();os.fsync(f.fileno())
    print(json.dumps(result))
if __name__=='__main__':main()
