"""Verify a real process restart against the same owned fixture."""
import importlib.util,json,os,pathlib
spec=importlib.util.spec_from_file_location('quality_http',pathlib.Path(__file__).with_name('quality-http.py'));h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
ready=json.loads(pathlib.Path(os.environ['S26_RESTART_READY']).read_text(encoding='utf-8-sig'))
jar=h.http.cookiejar.LWPCookieJar(str(h.STATE.with_suffix('.cookies')));jar.load(ignore_discard=True,ignore_expires=True);client=h.Client(jar)
assert client.get_json('/health')==dict(status='ready',version='0.9.0')
meta=client.get_json('/quality/jobs/'+ready['job']); snap=meta['snapshot']
assert snap['state']=='failed' and snap['error']['code']=='interrupted',snap
assert snap['job_revision']==ready['meta']['snapshot']['job_revision']+1
for key in ('model_sha256','variants_sha256','model_revision','analysis_version','artifact_id'):
    assert meta[key]==ready['meta'][key],key
assert client.request('GET','/quality/jobs/'+ready['job']+'/report')[0]==404
stable=client.request('GET','/quality/jobs/'+ready['stable_id']+'/report')[2];assert h.digest(stable)==ready['stable_sha256']
assert h.submit(client,ready['form'])['snapshot']['id']==ready['job']
status,_,raw=client.request('POST','/quality/jobs/'+ready['job']+'/retry',{'request_key':h.new_form(client)['fields']['request_key']});assert status==202,(status,raw)
child=json.loads(raw)['snapshot']['id']; child_meta,report,_=h.saved_report(client,child);assert child_meta['retry_of']==ready['job']
h.write('proof.json',dict(status='ACTUAL_PROCESS_RESTART_QUALITY_PASS',interrupted=ready['job'],retry=child,finished_report_bytes_identical=True,input_identity_preserved=True,no_automatic_resume=True,requests=h.records))
print('ACTUAL_PROCESS_RESTART_QUALITY_PASS')

