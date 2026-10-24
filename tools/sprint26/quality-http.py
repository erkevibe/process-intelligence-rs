#!/usr/bin/env python3
"""Finite checks against the owned, seeded Sprint26 loopback fixture only.

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

BASE = os.environ.get('S26_BASE_URL', '')
assert BASE == 'http://127.0.0.1:3147', 'owned fixture URL required'
assert os.environ.get('S26_OWNED_FIXTURE') == 'yes', 'explicit owned fixture required'
OUT = Path(os.environ['S26_HTTP_OUTPUT'])
STATE = Path(os.environ['S26_HTTP_STATE'])
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


def new_form(client, model='model-2', log='log-1'):
    status, _, raw = client.request('GET', f'/models/{model}/quality/new', accept='text/html')
    assert status == 200
    html = raw.decode()
    assert '<script>bad()' not in html and '<img onerror=bad>' not in html
    form = next(f for f in Forms(html).forms if f['action'] == f'/models/{model}/quality/jobs')
    assert re.fullmatch(r'[0-9]{10}\.[0-9a-f-]{36}', form['fields']['request_key'])
    form['fields']['log_id'] = log
    return form


def submit(client, form):
    status, _, raw = client.request('POST', form['action'], form['fields'])
    assert status == 202, (status, raw[:100])
    return json.loads(raw)


def saved_report(client, job):
    meta = client.wait(job)
    assert meta['snapshot']['state'] == 'completed', meta['snapshot']
    status, headers, raw = client.request('GET', f'/quality/jobs/{job}/report')
    assert status == 200 and headers.get('cache-control', headers.get('Cache-Control')) == 'no-store'
    return meta, json.loads(raw), raw


def multipart(payload, name='S26 restored quality'):
    boundary = 's26-owned-finite-boundary'
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="name"\r\n\r\n{name}\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="project.json"\r\n'
            'Content-Type: application/json\r\n\r\n').encode() + payload + f'\r\n--{boundary}--\r\n'.encode()
    return body, 'multipart/form-data; boundary=' + boundary


def basic():
    client = Client().login()
    health = client.get_json('/health')
    assert health == dict(status='ready', version='0.9.0')
    form = new_form(client)
    assert form['fields']['revision'] == '2', 'exact seeded fixture required'
    original = submit(client, form)['snapshot']['id']
    assert submit(client, form)['snapshot']['id'] == original
    meta, report, raw = saved_report(client, original)
    core = report['evaluation']['report']
    assert core['trace_count'] == 2
    assert core['metrics']['fitness']['fitness']['log_fitness'] == 1.0
    assert core['metrics']['precision']['scalar'] == 1.0
    (OUT / 'main-export.json').write_bytes(raw)
    stale = new_form(client)
    stale['fields']['revision'] = '1'
    assert client.request('POST', stale['action'], stale['fields'])[0] == 409
    status, headers, body = client.request('POST', stale['action'], stale['fields'], accept='text/html')
    assert status == 409 and 'text/html' in headers.get('content-type', headers.get('Content-Type', ''))
    assert 'Операция не подтверждена' in body.decode()
    oversized = new_form(client, log='log-4')
    assert client.request('POST', oversized['action'], oversized['fields'])[0] == 422
    bad = dict(form['fields'], unknown='x')
    assert client.request('POST', form['action'], bad)[0] == 422

    empty = submit(client, new_form(client, log='log-5'))['snapshot']['id']
    _, empty_report, _ = saved_report(client, empty)
    assert empty_report['evaluation']['report']['metrics']['fitness']['status'] == 'no_data'
    unsupported = submit(client, new_form(client, model='model-6'))['snapshot']['id']
    _, unsupported_report, _ = saved_report(client, unsupported)
    assert unsupported_report['evaluation']['report']['metrics']['fitness']['status'] != 'measured'
    nonfit = submit(client, new_form(client, log='log-3'))['snapshot']['id']
    _, nonfit_report, stable_raw = saved_report(client, nonfit)
    metrics = nonfit_report['evaluation']['report']['metrics']
    assert metrics['fitness']['fitness']['log_fitness'] == 0.6
    assert metrics['precision']['status'] == 'requires_fitting_log' and metrics['precision']['scalar'] is None

    viewer = Client().login('s25_quality_viewer')
    source_project = report['evaluation']['source_project_id']
    assert viewer.request('POST', f'/projects/{source_project}/open', {})[0] == 303
    viewer_form = new_form(viewer)
    assert viewer.request('POST', viewer_form['action'], viewer_form['fields'])[0] == 403
    assert viewer.request('GET', f'/quality/jobs/{nonfit}/report')[0] == 200
    status, _, body = viewer.request('GET', f'/quality/jobs/{nonfit}/events')
    assert status == 200 and b'datastar-patch-elements' in body and b'/retry' not in body
    outsider = Client().login('s25_quality_outsider')
    for suffix in ('', '/report', '/events', '/view'):
        status, _, body = outsider.request('GET', f'/quality/jobs/{nonfit}' + suffix)
        assert status == 404 and b'<script>bad()' not in body

    # A retry receipt remains useful even after the source task has been deleted.
    view = client.request('GET', f'/quality/jobs/{original}/view', accept='text/html')[2].decode()
    retry = next(f for f in Forms(view).forms if f['action'].endswith('/retry'))
    status, _, raw = client.request('POST', retry['action'], retry['fields'])
    assert status == 202
    child = json.loads(raw)['snapshot']['id']
    saved_report(client, child)
    assert client.request('POST', f'/quality/jobs/{original}/delete', {})[0] == 303
    status, _, raw = client.request('POST', retry['action'], retry['fields'])
    assert status == 202 and json.loads(raw)['snapshot']['id'] == child
    assert client.request('POST', f'/quality/jobs/{child}/delete', {})[0] == 303
    assert client.request('POST', retry['action'], retry['fields'])[0] == 409
    assert client.request('POST', form['action'], form['fields'])[0] == 409

    # Confirm acceptance, discard the response body, then recover by the same key.
    lost = new_form(client)
    request = urllib.request.Request(BASE + lost['action'])
    client.jar.add_cookie_header(request)
    payload = urllib.parse.urlencode(lost['fields']).encode()
    wire = (f"POST {lost['action']} HTTP/1.1\r\nHost: 127.0.0.1:3147\r\n"
            f"Cookie: {request.get_header('Cookie')}\r\nAccept: application/json\r\n"
            f"Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n").encode() + payload
    with socket.create_connection(('127.0.0.1', 3147), timeout=10) as connection:
        connection.sendall(wire)
        received = b''
        while b'\r\n\r\n' not in received:
            received += connection.recv(128)
            assert len(received) <= 16384
        assert received.startswith(b'HTTP/1.1 202')
    recovered = submit(client, lost)['snapshot']['id']
    assert submit(client, lost)['snapshot']['id'] == recovered
    saved_report(client, recovered)
    client.request('POST', f'/quality/jobs/{recovered}/delete', {})

    # Eight retained reports are an explicit capacity, not an eviction policy.
    temporary = []
    for _ in range(5):
        job = submit(client, new_form(client))['snapshot']['id']
        saved_report(client, job)
        temporary.append(job)
    full = new_form(client)
    assert client.request('POST', full['action'], full['fields'])[0] == 429
    for job in temporary:
        assert client.request('POST', f'/quality/jobs/{job}/delete', {})[0] == 303

    status, _, backup_raw = client.request('GET', '/backup')
    assert status == 200
    bundle = json.loads(backup_raw)
    (OUT / 'project-backup.json').write_bytes(backup_raw)
    body, kind = multipart(backup_raw)
    status, _, result = client.request('POST', '/restore', body, content_type=kind)
    assert status == 200
    restored = re.search(rb'/projects/(project-[0-9a-f]+)/open', result).group(1).decode()
    other = Client().login()
    assert other.request('POST', f'/projects/{restored}/open', {})[0] == 303
    assert other.request('GET', f'/quality/jobs/{nonfit}/report')[2] == stable_raw

    # Re-hash a false but in-range score: outer integrity must not confer truth.
    forged = json.loads(backup_raw)
    false_meta = forged['payload']['quality_jobs'][nonfit]
    false_report = forged['payload']['quality_artifacts'][false_meta['artifact_id']]['report']
    false_report['report']['metrics']['fitness']['fitness']['log_fitness'] = 0.5
    canonical = lambda value: json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True).encode()
    false_meta['report_sha256'] = digest(canonical(false_report))
    forged['digest_sha256'] = digest(canonical(forged['payload']))
    body, kind = multipart(canonical(forged), 'S26 false report must refuse')
    status, _, response = client.request('POST', '/restore', body, content_type=kind)
    assert status == 422 and json.loads(response)['code'] == 'quality_report_mismatch'
    assert client.request('GET', f'/quality/jobs/{nonfit}/report')[2] == stable_raw

    cookie_file = STATE.with_suffix('.cookies')
    jar = http.cookiejar.LWPCookieJar(str(cookie_file))
    for cookie in client.jar:
        jar.set_cookie(cookie)
    jar.save(ignore_discard=True, ignore_expires=True)
    state = dict(stable_id=nonfit, stable_sha256=digest(stable_raw), restored_project=restored)
    with STATE.open('x', encoding='utf-8') as stream:
        json.dump(state, stream)
    write('proof.json', dict(status='ACTUAL_NATIVE_DURABLE_HTTP_PASS', requests=records,
                            persistent_reports=True, idempotent_lost_response=True,
                            retry_after_source_deletion=True, backup_restore_bytes_identical=True,
                            coherent_forgery_refused=True, role_boundaries=True,
                            explicit_retention_capacity=True, physical_browser_claimed=False))


if __name__ == '__main__':
    assert sys.argv[1:] == ['basic']
    try:
        basic()
        print('ACTUAL_NATIVE_DURABLE_HTTP_PASS')
    except Exception as error:
        write('failure.json', dict(type=type(error).__name__, message=str(error), requests=records))
        raise
