#!/usr/bin/env python3
"""Finite protocol checks against the explicitly owned Sprint29 loopback fixture."""
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

assert os.environ.get('S29_BASE_URL') == 'http://127.0.0.1:3147'
assert os.environ.get('S29_OWNED_FIXTURE') == 'yes'
output = Path(os.environ['S29_HTTP_OUTPUT']).resolve(strict=True)
assert output.is_dir() and not any(output.iterdir())
seed_state = json.loads(Path(os.environ['S29_SEED_STATE']).read_text(encoding='utf-8-sig'))
seed_proof = json.loads(Path(os.environ['S29_SEED_PROOF']).read_text(encoding='utf-8-sig'))
assert seed_proof['status'] == 'S28_DISCOVERY_HTTP_PASS'
viewer_name = os.environ['S29_VIEWER_NAME']
assert re.fullmatch(r's29_api_viewer[0-9]{2}', viewer_name)
for key, value in dict(S28_BASE_URL=os.environ['S29_BASE_URL'], S28_OWNED_FIXTURE='yes', S28_HTTP_OUTPUT=str(output), S28_HTTP_STATE=str(output/'unused-state.json')).items():
    os.environ[key] = value
helper = Path(__file__).resolve().parents[1]/'sprint28'/'discovery-http.py'
spec = importlib.util.spec_from_file_location('s29_http_helper', helper)
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
cases = []


def check(name, condition):
    assert condition, name
    cases.append(dict(case=name, outcome='pass'))


def headers_lower(headers):
    return {key.lower(): value for key,value in headers.items()}


def login(username, password):
    c = h.Client()
    assert c.request('POST','/login',dict(username=username,password=password))[0] == 303
    return c


def backup(client, project, job):
    status, headers, raw = client.request('GET','/backup')
    assert status == 200 and headers_lower(headers).get('content-type','').startswith('application/json'), 'actual backup response'
    value = json.loads(raw)
    assert set(value) == {'schema_version','source_project_id','payload','digest_sha256'}
    assert type(value['schema_version']) is int and value['schema_version'] == 1 and value['source_project_id'] == project
    payload = value['payload']
    encoded = json.dumps(payload,ensure_ascii=False,allow_nan=False,sort_keys=True,separators=(',',':')).encode()
    assert h.digest(encoded) == value['digest_sha256'], 'backup payload digest'
    assert seed_state['model'] in payload['models'] and seed_state['training_log'] in payload['logs']
    assert payload['discovery_jobs'][job]['snapshot']['state'] == 'completed'
    assert payload['discovery_jobs'][job]['model_id'] == seed_state['model']
    return raw


def main():
    anonymous = h.Client()
    job = seed_state['job']
    path = '/discovery/jobs/' + job
    status, headers, raw = anonymous.request('GET', path)
    check('unauthenticated_redirect_is_not_json_success', status == 303 and headers_lower(headers).get('location') == '/login')
    c = login('s28_owner', 'S28DiscoveryOwnerPassword123')
    meta = c.get_json(path)
    project = meta['source_project_id']
    check('saved_discovery_identity', meta['snapshot']['id'] == job and meta['snapshot']['state'] == 'completed' and meta['model_id'] == seed_state['model'])
    assert c.request('POST','/users',dict(username=viewer_name,password='S29ApiViewerPassword123'))[0] == 303
    viewer = login(viewer_name, 'S29ApiViewerPassword123')
    status, headers, raw = viewer.request('POST',f'/projects/{project}/open',{})
    check('ungranted_user_cannot_open_project', status == 403 and json.loads(raw)['code'] == 'access_denied')
    for read_path in (path,path+'/report'):
        status, headers, raw = viewer.request('GET',read_path)
        check('foreign_project_hides_resource:' + read_path, status == 404 and json.loads(raw)['code'] == 'not_found')
    assert c.request('POST',f'/projects/{project}/members',dict(username=viewer_name,role='viewer'))[0] == 303
    assert viewer.request('POST',f'/projects/{project}/open',{})[0] == 303
    qrecord = next(row for row in seed_proof['requests'] if re.fullmatch(r'/quality/jobs/job-[0-9]+/report',row['path']) and row['status'] == 200)
    qpath = qrecord['path']
    status, headers, original = c.request('GET',qpath)
    check('completed_quality_bytes_survive_new_process', status == 200 and h.digest(original) == qrecord['sha256'])
    downloaded = json.loads(original)
    check('quality_export_identity_and_schema', downloaded['schema_version'] == 1 and downloaded['evaluation']['model_id'] == seed_state['model'])
    before = backup(c,project,job)
    for read_path in (path,path+'/report',qpath):
        status, headers, raw = c.request('GET',read_path)
        check('owner_no_store:' + read_path, status == 200 and headers_lower(headers).get('cache-control') == 'no-store')
    status, headers, raw = c.request('GET',path+'/events',accept='text/event-stream')
    check('terminal_metadata_sse_closes', status == 200 and headers_lower(headers).get('content-type','').startswith('text/event-stream') and b'datastar-patch-elements' in raw and b'weighted_total_cost' not in raw and b'"sequence"' not in raw)
    check('terminal_sse_no_store', headers_lower(headers).get('cache-control') == 'no-store')
    form = dict(analysis_version=meta['analysis_version'],model_name=meta['model_name'],request_key=meta['request_key'])
    action = f"/logs/{meta['log_id']}/discovery/jobs"
    for index in range(3):
        status, headers, raw = c.request('POST',action,form)
        value = json.loads(raw)
        check('replay_same_id_' + str(index), status == 202 and value['snapshot']['id'] == job and value['model_id'] == seed_state['model'])
    conflicting = dict(form,model_name=form['model_name']+' changed')
    status, headers, raw = c.request('POST',action,conflicting)
    check('same_key_changed_form_409', status == 409 and json.loads(raw)['code'] == 'discovery_request_conflict')
    malformed = dict(form,request_key='not-a-key')
    status, headers, raw = c.request('POST',action,malformed)
    check('domain_json_error_422', status == 422 and headers_lower(headers).get('content-type','').startswith('application/json') and json.loads(raw)['code'] == 'discovery_request_key')
    status, headers, raw = c.request('POST',action,malformed,accept='text/html')
    check('domain_html_error_422', status == 422 and headers_lower(headers).get('content-type','').startswith('text/html') and 'Операция не подтверждена' in raw.decode())
    status, headers, raw = c.request('POST',action,dict(form,unknown='x'))
    check('unknown_form_field_refused_before_mutation', status == 422)
    status, headers, raw = c.request('GET','/discovery/jobs/job-999999999')
    check('unknown_scoped_job_404', status == 404 and json.loads(raw)['code'] == 'not_found')
    after = backup(c,project,job)
    check('reads_replays_and_refusals_preserve_project_backup_bytes', before == after)
    for read_path in (path,path+'/report',qpath):
        status, headers, raw = viewer.request('GET',read_path)
        check('viewer_read:' + read_path, status == 200 and headers_lower(headers).get('cache-control') == 'no-store')
    for suffix in ('retry','cancel','delete'):
        status, headers, raw = viewer.request('POST',path+'/'+suffix,dict(request_key=form['request_key']))
        check('viewer_write_forbidden_' + suffix, status == 403 and json.loads(raw)['code'] == 'access_denied')
    final_backup = backup(c,project,job)
    check('viewer_refusals_preserve_verified_project_backup_bytes', before == final_backup)
    h.write('proof.json',dict(status='S29_API_CONTRACT_PROBE_PASS',schema_version=1,cases=cases,requests=h.records,
        server_version=c.get_json('/health')['version'],completed_report_sha256=h.digest(original),
        project_backup_before_sha256=h.digest(before),project_backup_after_sha256=h.digest(after),
        replay_job_id=job,replay_model_id=seed_state['model'],synthetic_fixture_only=True,
        deployment_tls_ha_claimed=False,api_support_sla_claimed=False))
    print(json.dumps(dict(status='S29_API_CONTRACT_PROBE_PASS',cases=len(cases),requests=len(h.records))))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        h.write('failure.json',dict(type=type(error).__name__,message=str(error),cases=cases,requests=h.records))
        raise
