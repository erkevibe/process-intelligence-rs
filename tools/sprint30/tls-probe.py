#!/usr/bin/env python3
"""Owned ephemeral Linux TLS fixture; no insecure TLS modes or external writes."""
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request

assert os.environ.get('GITHUB_ACTIONS') == 'true'
assert os.environ.get('S30_OWNED_TLS_FIXTURE') == 'yes'
root = Path(os.environ['S30_TLS_OUTPUT']).resolve(strict=True)
ca = root / 'ca.pem'
seed = json.loads(Path(os.environ['S30_SEED_STATE']).read_text())
context = ssl.create_default_context(cafile=str(ca))
assert context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED
cases = []


def check(name, condition):
    assert condition, name
    cases.append(dict(case=name, outcome='pass'))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


jar = http.cookiejar.CookieJar()
client = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=context),
    urllib.request.HTTPCookieProcessor(jar), NoRedirect())


def request(method, path, body=None, headers=None, base='https://localhost:8443', transport=None):
    headers=dict(headers or {})
    if method not in ('GET','HEAD'):
        headers.setdefault('Origin','https://localhost:8443')
    if isinstance(body, dict):
        body = urllib.parse.urlencode(body).encode()
        headers = dict(headers or {}, **{'Content-Type':'application/x-www-form-urlencoded'})
    req = urllib.request.Request(base+path, data=body, headers=headers or {}, method=method)
    try:
        response = (transport or client).open(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read(8*1024*1024+1)
        assert len(raw) <= 8*1024*1024
        return response.status, response.headers, raw


status, headers, raw = request('GET', '/health')
check('trusted_ca_and_hostname_health', status == 200 and json.loads(raw)['status'] == 'ready')
check('hsts_present', headers.get('Strict-Transport-Security') == 'max-age=86400')
try:
    with socket.create_connection(('127.0.0.1',8443), timeout=5) as sock:
        with ssl.create_default_context().wrap_socket(sock, server_hostname='localhost'):
            raise AssertionError('untrusted CA accepted')
except ssl.SSLCertVerificationError:
    check('untrusted_ca_refused', True)
wrong_name = subprocess.run(['openssl','s_client','-connect','127.0.0.1:8443',
    '-servername','localhost','-verify_hostname','wrong.invalid',
    '-verify_return_error','-CAfile',str(ca)], input=b'', capture_output=True, timeout=10)
check('trusted_ca_wrong_hostname_refused', wrong_name.returncode != 0 and b'hostname mismatch' in wrong_name.stderr.lower())
status, headers, _ = request('GET','/quality?tls=1',base='http://localhost:8080')
check('http_redirect_preserves_path_query', status == 308 and headers.get('Location') == 'https://localhost:8443/quality?tls=1')
status, _, raw = request('GET','/backup',headers={'Forwarded':'proto=https;for=owner','X-Remote-User':'owner','X-User-Id':'owner'})
check('spoofed_actor_headers_remain_anonymous', status == 403 and json.loads(raw)['code'] == 'access_denied')
status, headers, _ = request('POST','/login',dict(username='s28_owner',password='S28DiscoveryOwnerPassword123'))
cookie = headers.get('Set-Cookie','')
check('login_cookie_secure_httponly_samesite', status == 303 and all(v in cookie for v in ['pi_session=','; Secure','; HttpOnly','; SameSite=Strict']))
check('cookie_jar_secure', bool(list(jar)) and all(c.secure for c in jar))
status, _, _ = request('POST','/quota',dict(revision=0,payload_allowance=0,mode='disabled'),headers={'Origin':'https://evil.invalid','X-Forwarded-Proto':'https'})
check('foreign_origin_refused_without_proxy_rewrite', status == 403)
status, _, raw = request('GET','/quota/status')
quota = json.loads(raw)
check('owner_quota_status_through_tls', status == 200 and quota['enabled'] is False)
status, _, _ = request('POST','/quota',dict(revision=quota['revision'],payload_allowance=quota['payload_used']+1000000,mode='enabled'))
check('owner_enables_quota_through_tls', status == 303)
status, _, raw = request('GET','/quota/status')
enabled_quota = json.loads(raw)
check('enabled_quota_keeps_payload_accounting', status == 200 and enabled_quota['enabled'] is True and enabled_quota['payload_used'] == quota['payload_used'])
status, _, raw = request('GET','/discovery/jobs/'+seed['job'])
check('authenticated_saved_discovery', status == 200 and json.loads(raw)['snapshot']['state'] == 'completed')
status, headers, raw = request('GET','/discovery/jobs/'+seed['job']+'/events',headers={'Accept':'text/event-stream'})
check('terminal_sse_flushed_through_proxy', status == 200 and 'text/event-stream' in headers.get('Content-Type','') and b'datastar-patch-elements' in raw and seed['job'].encode() in raw)
status, _, before = request('GET','/backup')
check('authenticated_backup_through_tls', status == 200 and json.loads(before)['schema_version'] == 1)
status, _, _ = request('POST','/quota',dict(revision='0',payload_allowance='0',mode='enabled'))
check('stale_write_keeps_conflict_through_proxy', status == 409)
status, _, after = request('GET','/backup')
check('refused_write_preserves_backup_bytes', status == 200 and before == after)
status, _, _ = request('POST','/quota',dict(revision=enabled_quota['revision'],payload_allowance=0,mode='disabled'))
check('owner_disables_quota_through_tls', status == 303)
status, _, raw = request('GET','/quota/status')
check('disabled_quota_preserves_data', status == 200 and json.loads(raw)['enabled'] is False and json.loads(raw)['payload_used'] == quota['payload_used'])
viewer_jar = http.cookiejar.CookieJar()
viewer = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=context), urllib.request.HTTPCookieProcessor(viewer_jar), NoRedirect())
status, headers, _ = request('POST','/login',dict(username='s29_api_viewer01',password='S29ApiViewerPassword123'),transport=viewer)
check('viewer_tls_login_secure_cookie', status == 303 and bool(list(viewer_jar)) and all(c.secure for c in viewer_jar))
status, _, _ = request('POST','/projects/'+json.loads(before)['source_project_id']+'/open',{},transport=viewer)
check('viewer_selects_granted_project_through_tls', status == 303)
status, _, baseline = request('GET','/backup')
assert status == 200
status, _, raw = request('GET','/quota/status',transport=viewer)
viewer_quota = json.loads(raw)
check('viewer_reads_quota_through_tls', status == 200 and viewer_quota['enabled'] is False and viewer_quota['payload_used'] == quota['payload_used'])
status, _, raw = request('GET','/quota',transport=viewer)
check('viewer_quota_page_has_no_owner_form', status == 200 and b'name="payload_allowance"' not in raw)
status, _, raw = request('POST','/quota',dict(revision=viewer_quota['revision'],mode='enabled',payload_allowance=0),transport=viewer)
check('viewer_quota_write_refused_through_tls', status == 403 and json.loads(raw)['code'] == 'access_denied')
status, _, after = request('GET','/backup')
check('viewer_tls_refusal_preserves_backup_bytes', status == 200 and after == baseline)
status, headers, _ = request('POST','/logout',{})
check('logout_expiry_cookie_stays_secure', status == 303 and '; Secure' in headers.get('Set-Cookie','') and 'Max-Age=0' in headers.get('Set-Cookie',''))
status, _, raw = request('GET','/backup')
check('logout_session_revoked', status == 403 and json.loads(raw)['code'] == 'access_denied')
proof = dict(status='S30_LINUX_TLS_PROBE_PASS', cases=cases,
    ca_sha256=hashlib.sha256(ca.read_bytes()).hexdigest(),
    certificate_sha256=hashlib.sha256((root/'server.pem').read_bytes()).hexdigest(),
    backup_sha256=hashlib.sha256(before).hexdigest(),
    scope='ephemeral Linux Caddy fixture using explicit test CA; public DNS, ACME, real host, systemd runtime and production admission excluded')
(root/'tls-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps(proof))
