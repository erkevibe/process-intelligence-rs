#!/usr/bin/env python3
"""Finite checks against the owned, seeded Sprint28 loopback fixture only.

Raw replies, test cookies and exports belong in a private output directory.
This is an HTTP check, not a physical-browser or load-test claim.
"""
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

BASE = os.environ.get('S28_BASE_URL', '')
assert BASE == 'http://127.0.0.1:3147', 'owned fixture URL required'
assert os.environ.get('S28_OWNED_FIXTURE') == 'yes', 'explicit owned fixture required'
OUT = Path(os.environ['S28_HTTP_OUTPUT'])
STATE = Path(os.environ['S28_HTTP_STATE'])
assert OUT.is_dir() and not any(OUT.iterdir()), 'new private output required'
CAP = 8 * 1024 * 1024
records = []


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write(name, value):
    raw = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode()
    with (OUT / name).open('xb') as stream:
        stream.write(raw)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Client:
    def __init__(self, jar=None):
        self.jar = jar or http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(self.jar), NoRedirect())

    def request(self, method, path, body=None, accept='application/json', content_type=None):
        assert path.startswith('/') and '\r' not in path and '\n' not in path
        if isinstance(body, dict):
            body = urllib.parse.urlencode(body).encode()
            content_type = 'application/x-www-form-urlencoded'
        request = urllib.request.Request(BASE + path, data=body, method=method)
        request.add_header('Accept', accept)
        if content_type:
            request.add_header('Content-Type', content_type)
        try:
            response = self.opener.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(CAP + 1)
            assert len(raw) <= CAP, 'reply limit'
            status = response.code
            headers = dict(response.headers.items())
        index = len(records)
        records.append(dict(method=method, path=path, status=status, bytes=len(raw), sha256=digest(raw)))
        with (OUT / f'{index:03}.body').open('xb') as stream:
            stream.write(raw)
        return status, headers, raw

    def login(self, user='s25_quality_owner'):
        password = ('S25QualityOwnerPassword123' if user == 's25_quality_owner'
                    else 'S25QualityMemberPassword123')
        assert self.request('POST', '/login', dict(username=user, password=password))[0] == 303
        return self

    def get_json(self, path):
        status, _, raw = self.request('GET', path)
        assert status == 200, (path, status)
        return json.loads(raw)

    def wait(self, job):
        until = time.monotonic() + 20
        while time.monotonic() < until:
            value = self.get_json('/quality/jobs/' + job)
            if value['snapshot']['state'] in ('completed', 'failed', 'cancelled'):
                return value
            time.sleep(0.05)
        raise AssertionError('job did not reach a terminal state')


class Forms(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.forms = []
        self.current = None
        self.select = None
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'form':
            self.current = dict(action=attrs.get('action'), fields={})
            self.forms.append(self.current)
        elif self.current is not None:
            if tag == 'input' and 'name' in attrs:
                self.current['fields'][attrs['name']] = attrs.get('value', '')
            elif tag == 'select':
                self.select = attrs.get('name')
            elif tag == 'option' and self.select:
                if self.select not in self.current['fields'] or 'selected' in attrs:
                    self.current['fields'][self.select] = attrs.get('value', '')

    def handle_endtag(self, tag):
        if tag == 'form':
            self.current = None
        elif tag == 'select':
            self.select = None

def upload(client, path, raw, filename):
    boundary = 'PiSprint28FiniteBoundary'
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\nContent-Type: application/xml\r\n\r\n'.encode() + raw + f'\r\n--{boundary}--\r\n'.encode())
    return client.request('POST', path, body, 'text/html', 'multipart/form-data; boundary=' + boundary)


def wait(client, prefix, job):
    until = time.monotonic() + 30
    while time.monotonic() < until:
        value = client.get_json(prefix + job)
        if value['snapshot']['state'] in ('completed', 'failed', 'cancelled'):
            assert value['snapshot']['state'] == 'completed', value['snapshot']
            return value
        time.sleep(0.05)
    raise AssertionError('terminal timeout')


def form(client, path, action):
    status, _, raw = client.request('GET', path, accept='text/html')
    assert status == 200
    return next(f for f in Forms(raw.decode()).forms if f['action'] == action)


def main():
    c = Client()
    assert c.request('POST', '/login', dict(username='s28_owner', password='S28DiscoveryOwnerPassword123'))[0] == 303
    training = b'<log xmlns="http://www.xes-standard.org/"><trace><string key="concept:name" value="t1"/><event><string key="concept:name" value="A"/></event><event><string key="concept:name" value="B"/></event><event><string key="concept:name" value="C"/></event></trace><trace><string key="concept:name" value="t2"/><event><string key="concept:name" value="A"/></event><event><string key="concept:name" value="B"/></event><event><string key="concept:name" value="B"/></event><event><string key="concept:name" value="C"/></event></trace></log>'
    status, _, raw = upload(c, '/logs', training, 'S28 training.xes')
    assert status == 200
    status, _, raw = c.request('GET', '/logs', accept='text/html')
    logs = re.findall(r'href="/logs/(log-[0-9]+)"', raw.decode())
    assert logs
    log = max(logs, key=lambda x:int(x.split('-')[1]))
    f = form(c, f'/logs/{log}/discovery/new', f'/logs/{log}/discovery/jobs')
    f['fields']['model_name'] = 'S28 HTTP saved model'
    status, headers, raw = c.request('POST', f['action'], f['fields'])
    assert status == 202, (status, raw[:160])
    accepted = json.loads(raw)
    job = accepted['snapshot']['id']
    done = wait(c, '/discovery/jobs/', job)
    model = done['model_id']
    assert done['snapshot']['id'] == job and done['log_id'] == log
    assert done['analysis_version'] == int(f['fields']['analysis_version'])
    status, _, replay = c.request('POST', f['action'], f['fields'])
    assert status == 202 and json.loads(replay)['snapshot']['id'] == job
    status, _, raw = c.request('GET', f'/discovery/jobs/{job}/report')
    assert status == 200
    report = json.loads(raw)
    assert report['metadata'] == done
    assert report['metadata']['snapshot']['result_id'] == report['artifact']['id']
    expected_variants = [dict(sequence=['A', 'B', 'B', 'C'], frequency=1), dict(sequence=['A', 'B', 'C'], frequency=1)]
    assert report['artifact']['input']['variants'] == expected_variants
    variants_sha = digest(json.dumps(expected_variants, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode())
    assert digest(json.dumps(report['artifact']['input']['variants'], sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()) == variants_sha
    assert done['variants_sha256'] == variants_sha
    output = report['artifact']['output']
    training_report = output['training_report']
    assert training_report['variants_sha256'] == variants_sha
    stored_model = c.get_json(f'/models/{model}/json')
    assert stored_model['id'] == model and stored_model['model'] == output['model']
    assert stored_model['source_log'] == log and stored_model['training']['job_id'] == job
    model_sha = digest(json.dumps(stored_model['model'], ensure_ascii=False, separators=(',', ':')).encode())
    assert output['model_sha256'] == training_report['model_sha256'] == model_sha
    def ordered_tree(tree):
        value = dict(operator=tree['operator'])
        if 'children' in tree:
            children = tree['children']
            value['children'] = ([ordered_tree(child) for child in children] if isinstance(children, list) else ordered_tree(children) if isinstance(children, dict) else children)
        return value
    ordered_output = dict(model=stored_model['model'], tree=ordered_tree(output['tree']), exact_variant_fallbacks=output['exact_variant_fallbacks'], model_sha256=model_sha, training_report=training_report)
    assert digest(json.dumps(ordered_output, ensure_ascii=False, separators=(',', ':')).encode()) == done['output_sha256']
    assert training_report['trace_count'] == 2 and training_report['variant_count'] == 2
    assert all(training_report['metrics'][name]['status'] == 'measured' for name in ('fitness', 'precision', 'simplicity'))
    fitness = training_report['metrics']['fitness']
    assert fitness['status'] == 'measured' and type(fitness['fitness']['log_fitness']) in (int, float) and fitness['fitness']['log_fitness'] == 1
    assert fitness['integer_components']['traces'] == 2 and fitness['integer_components']['events'] == 7
    assert fitness['integer_components']['weighted_total_cost'] == 0
    (OUT/'discovery-report.json').write_bytes(raw)
    status, _, bpmn = c.request('GET', f'/discovery/jobs/{job}/bpmn')
    assert status == 200
    (OUT/'discovered.bpmn').write_bytes(bpmn)
    status, headers, _ = upload(c, '/models/import', bpmn, 'S28 roundtrip.bpmn')
    assert status == 303
    imported = headers.get('Location', headers.get('location')).split('/')[-1]
    control = training.replace(b'value="t1"', b'value="heldout1"').replace(b'value="t2"', b'value="heldout2"')
    assert upload(c, '/logs', control, 'S28 separate control.xes')[0] == 200
    _, _, raw = c.request('GET', '/logs', accept='text/html')
    control_log = max(re.findall(r'href="/logs/(log-[0-9]+)"', raw.decode()), key=lambda x:int(x.split('-')[1]))
    assert control_log != log
    metrics = []
    for mid in (model, imported):
        qf = form(c, f'/models/{mid}/quality/new?control=1', f'/models/{mid}/quality/jobs')
        assert not qf['fields'].get('log_id'), 'control requires explicit selection'
        qf['fields']['log_id'] = control_log
        status, _, raw = c.request('POST', qf['action'], qf['fields'])
        assert status == 202
        qid = json.loads(raw)['snapshot']['id']
        wait(c, '/quality/jobs/', qid)
        value = c.get_json(f'/quality/jobs/{qid}/report')
        assert value['model_id'] == mid and value['log_id'] == control_log
        assert value['report']['trace_count'] == 2 and value['report']['variant_count'] == 2
        assert all(value['report']['metrics'][name]['status'] == 'measured' for name in ('fitness', 'precision', 'simplicity'))
        assert value['report']['metrics']['fitness']['status'] == 'measured'
        assert value['report']['metrics']['fitness']['fitness']['log_fitness'] == 1
        assert value['report']['metrics']['fitness']['integer_components']['events'] == 7
        metrics.append(value['report']['metrics'])
        if mid == model:
            assert value['training_relation'] == 'same_variants_other_log'
    assert metrics[0] == metrics[1]
    assert metrics[0] == report['artifact']['output']['training_report']['metrics']
    heldout = ('<log xmlns="http://www.xes-standard.org/"><trace><string key="concept:name" value="heldout-b3"/>' + ''.join(f'<event><string key="concept:name" value="{label}"/></event>' for label in ('A', 'B', 'B', 'B', 'C')) + '</trace></log>').encode()
    assert upload(c, '/logs', heldout, 'S28 control B3.xes')[0] == 200
    _, _, raw = c.request('GET', '/logs', accept='text/html')
    heldout_log = max(re.findall(r'href="/logs/(log-[0-9]+)"', raw.decode()), key=lambda x:int(x.split('-')[1]))
    assert heldout_log not in (log, control_log)
    with STATE.open('x', encoding='utf-8') as stream:
        json.dump(dict(job=job, model=model, training_log=log, control_log=control_log, heldout_log=heldout_log, imported_model=imported), stream)
    write('proof.json', dict(status='S28_DISCOVERY_HTTP_PASS', requests=records, saved_model=True, roundtrip_metrics_identical=True, explicit_control_selection=True, duplicate_variants_honestly_classified=True, physical_browser_claimed=False))


if __name__ == '__main__':
    try:
        main()
        print('S28_DISCOVERY_HTTP_PASS')
    except Exception as error:
        write('failure.json', dict(type=type(error).__name__, message=str(error), requests=records))
        raise
