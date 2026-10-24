#!/usr/bin/env python3
"""Read a saved report across an owned PostgreSQL dump/restore with quota zero."""
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

assert os.environ.get('GITHUB_ACTIONS') == 'true'
assert os.environ.get('S30_OWNED_QUOTA_DR') == 'yes'
phase = sys.argv[1]
assert phase in ('before', 'after')
root = Path(os.environ['S30_DR_OUTPUT']).resolve(strict=True)
seed = json.loads(Path('.local/sprint29/ci-seed/proof.json').read_text())
report = next(x for x in seed['requests'] if re.fullmatch(r'/quality/jobs/job-[0-9]+/report', x['path']) and x['status'] == 200)
jar = http.cookiejar.CookieJar()
client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


client.add_handler(NoRedirect())


def request(method, path, data=None):
    headers = {}
    if data is not None:
        data = urllib.parse.urlencode(data).encode()
        headers = {'Content-Type': 'application/x-www-form-urlencoded', 'Origin': 'http://127.0.0.1:3147'}
    req = urllib.request.Request('http://127.0.0.1:3147' + path, data=data, headers=headers, method=method)
    try:
        response = client.open(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read(8 * 1024 * 1024 + 1)
        assert len(raw) <= 8 * 1024 * 1024
        return response.status, raw


assert request('POST', '/login', dict(username='s28_owner', password='S28DiscoveryOwnerPassword123'))[0] == 303
code, raw = request('GET', '/quota/status')
assert code == 200
quota = json.loads(raw)
if phase == 'before':
    assert quota['enabled'] is False and quota['payload_used'] > 0
    assert request('POST', '/quota', dict(revision=quota['revision'], mode='enabled', payload_allowance=0))[0] == 303
    code, raw = request('GET', '/quota/status')
    assert code == 200
    quota = json.loads(raw)
assert quota['enabled'] is True and quota['payload_allowance'] == 0 and quota['payload_used'] > 0
code, raw = request('GET', report['path'])
assert code == 200 and hashlib.sha256(raw).hexdigest() == report['sha256']
(root / (phase + '-report.json')).write_bytes(raw)
value = dict(quota=quota, report_path=report['path'], report_sha256=hashlib.sha256(raw).hexdigest())
if phase == 'after':
    before = json.loads((root / 'before.json').read_text())
    assert before == value, 'restored quota, revision, project or report changed'
    value = dict(status='S30_QUOTA_POSTGRES_DR_PASS', cases=[
        'enabled_zero_allowance_survives_full_pg_restore',
        'overlimit_usage_and_revision_preserved',
        'saved_quality_report_exact_bytes_preserved',
        'saved_report_readable_after_new_process_and_login',
    ], observation=value, scope='disposable CI database; no production RPO/RTO or remote-host claim')
(root / (phase + '.json')).write_text(json.dumps(value, indent=2) + '\n')
print(json.dumps(value))
