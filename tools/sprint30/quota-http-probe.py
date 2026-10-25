#!/usr/bin/env python3
"""Positive owner quota form and real imports on the explicitly owned fresh app."""
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import tomllib
import urllib.error
import urllib.parse
import urllib.request

assert os.environ.get('S30_OWNED_QUOTA_HTTP') == 'yes'
assert os.environ.get('S30_BASE_URL') == 'http://127.0.0.1:3147'
out=Path(os.environ['S30_QUOTA_HTTP_OUTPUT']).resolve(strict=True)
assert not any(out.iterdir())
cases=[]
requests=[]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):
        return None


jar=http.cookiejar.CookieJar()
client=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(jar),NoRedirect())


def request(method,path,body=None,content_type=None):
    if isinstance(body,dict):
        body=urllib.parse.urlencode(body).encode()
        content_type='application/x-www-form-urlencoded'
    req=urllib.request.Request(os.environ['S30_BASE_URL']+path,data=body,method=method)
    if method not in ('GET','HEAD'):
        req.add_header('Origin',os.environ['S30_BASE_URL'])
    if content_type:
        req.add_header('Content-Type',content_type)
    try:
        response=client.open(req,timeout=20)
    except urllib.error.HTTPError as error:
        response=error
    with response:
        raw=response.read(2*1024*1024+1)
        assert len(raw)<=2*1024*1024
        status=response.status
    requests.append(dict(method=method,path=path,status=status,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))
    (out/f'{len(requests)-1:03}.body').write_bytes(raw)
    return status,raw


def check(name,condition):
    assert condition,name
    cases.append(dict(case=name,outcome='pass'))


def status():
    code,raw=request('GET','/quota/status')
    assert code==200
    return json.loads(raw)


def policy(current,mode,limit):
    return request('POST','/quota',dict(revision=current['revision'],mode=mode,payload_allowance=limit))[0]


def upload():
    xml='<log><trace><string key="concept:name" value="quota-case"/><event><string key="concept:name" value="A"/></event><event><string key="concept:name" value="B"/></event></trace></log>'
    body=f'--s30-http\r\nContent-Disposition: form-data; name="file"; filename="quota-http.xes"\r\nContent-Type: application/xml\r\n\r\n{xml}\r\n--s30-http--\r\n'.encode()
    return request('POST','/logs',body,'multipart/form-data; boundary=s30-http')


code,raw=request('GET','/health')
expected_version=tomllib.loads(Path('Cargo.toml').read_text())['package']['version']
health=json.loads(raw)
# Preserve the historical observation ID while requiring the exact current build.
check('actual_011_ready',code==200 and health['status']=='ready' and health['version']==expected_version)
code,_=request('POST','/setup',dict(username='s30_http_owner',password='S30QuotaHttpOwnerPassword123'))
check('fresh_owner_setup',code==303)
initial=status()
check('new_project_default_disabled',initial['enabled'] is False and initial['payload_used']==0)
check('owner_enables_zero_allowance',policy(initial,'enabled',0)==303)
enabled=status()
check('enabled_policy_persisted',enabled['enabled'] is True and enabled['payload_allowance']==0 and enabled['revision']>initial['revision'])
code,before=request('GET','/backup')
check('empty_enabled_backup',code==200 and json.loads(before)['payload']['quota_policy']==dict(metric_version=1,payload_allowance=0))
check('stale_owner_form_conflict',policy(initial,'disabled',0)==409)
code,after=request('GET','/backup')
check('stale_form_preserves_backup_bytes',code==200 and after==before)
code,raw=upload()
check('zero_allowance_import_refused',code>=400 and b'project_quota' in raw)
code,after=request('GET','/backup')
check('refused_import_preserves_project_bytes',code==200 and after==before and status()['payload_used']==0)
check('owner_increases_allowance',policy(enabled,'enabled',1000000)==303)
code,raw=upload()
check('real_import_with_allowance_succeeds',code==200)
populated=status()
check('real_payload_accounted',0<populated['payload_used']<=1000000)
check('owner_can_lower_below_used',policy(populated,'enabled',0)==303)
overfull=status()
check('overlimit_policy_kept',overfull['payload_allowance']==0 and overfull['payload_used']==populated['payload_used'])
code,_=request('GET','/logs')
check('overlimit_reads_remain_available',code==200)
code,before=request('GET','/backup')
check('overlimit_backup_available',code==200)
code,raw=upload()
check('overlimit_growth_refused',code>=400 and b'project_quota' in raw)
code,after=request('GET','/backup')
check('overlimit_growth_full_rollback',code==200 and after==before)
check('owner_disables_limit',policy(overfull,'disabled',0)==303)
disabled=status()
check('disabled_policy_persisted',disabled['enabled'] is False and disabled['payload_used']==overfull['payload_used'])
code,raw=request('GET','/quota')
check('owner_form_rendered',code==200 and b'name="payload_allowance"' in raw and b'name="revision"' in raw)
proof=dict(status='S30_QUOTA_OWNER_HTTP_PASS',cases=cases,requests=requests,project_id=json.loads(before)['source_project_id'],payload_used=disabled['payload_used'],scope='actual owned HTTP and forms, not a physical browser or load claim')
(out/'proof.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps(proof))
