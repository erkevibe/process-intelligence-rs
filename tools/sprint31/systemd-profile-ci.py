#!/usr/bin/env python3
"""Destructive fixture setup ONLY on a fresh GitHub-hosted Ubuntu VM.

This qualifies the downloaded profile; it is not an operator installation tool.
Owned services are stopped, while files/users remain for VM decommissioning.
"""
import grp
import hashlib
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import signal
import socket
import ssl
import subprocess
import tarfile
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

APP = 'process-intelligence.service'
PROXY = 'caddy.service'
ORIGIN = 'https://localhost:8443'
VENDOR_UNIT = 'https://raw.githubusercontent.com/caddyserver/dist/f94a1d2626835ff4157e85296fb8e4fa5500e0fb/init/caddy.service'
VENDOR_UNIT_SHA = '6c271e030644bd36a0c8956885934f16c928f88202bc126f12cde519ef9693ff'
CADDY_ARCHIVE = 'https://github.com/caddyserver/caddy/releases/download/v2.11.7/caddy_2.11.7_linux_amd64.tar.gz'
CADDY_ARCHIVE_SHA = '727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b'
TARGETS = ['/opt/process-intelligence', '/etc/process-intelligence', '/etc/caddy',
           '/usr/bin/caddy', '/etc/systemd/system/process-intelligence.service',
           '/etc/systemd/system/caddy.service', '/etc/systemd/system/caddy.service.d',
           '/etc/systemd/system/process-intelligence.service.d',
           '/var/lib/caddy', '/var/log/caddy']


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class SubmissionForm(HTMLParser):
    def __init__(self, action):
        super().__init__()
        self.target, self.action, self.fields = action, None, {}

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        if tag == 'form':
            self.action = values.get('action')
        if tag == 'input' and self.action == self.target and values.get('type') == 'hidden':
            name = values['name']
            assert name not in self.fields
            self.fields[name] = values['value']

    def handle_endtag(self, tag):
        if tag == 'form':
            self.action = None


class Client:
    def __init__(self, ca, observations):
        self.jar = http.cookiejar.CookieJar()
        context = ssl.create_default_context(cafile=str(ca))
        assert context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=context), urllib.request.HTTPCookieProcessor(self.jar), NoRedirect())
        self.observations = observations

    def request(self, method, path, body=None, content_type=None):
        assert path.startswith('/') and '\n' not in path and '\r' not in path
        if isinstance(body, dict):
            body = urllib.parse.urlencode(body).encode()
            content_type = 'application/x-www-form-urlencoded'
        headers = {'Accept': 'application/json'}
        if method not in ('GET', 'HEAD'):
            headers['Origin'] = ORIGIN
        if content_type:
            headers['Content-Type'] = content_type
        req = urllib.request.Request(ORIGIN + path, data=body, headers=headers, method=method)
        try:
            response = self.opener.open(req, timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(4 * 1024 * 1024 + 1)
            assert len(raw) <= 4 * 1024 * 1024
            code = response.status
        self.observations.append(dict(method=method, path=path, status=code, bytes=len(raw), sha256=digest(raw)))
        return code, raw

    def get(self, path):
        code, raw = self.request('GET', path)
        assert code == 200, 'read failed: ' + path
        return json.loads(raw)


class Fixture:
    def __init__(self):
        assert os.environ.get('GITHUB_ACTIONS') == 'true'
        assert os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
        assert os.environ.get('ImageOS') == 'ubuntu24'
        assert os.environ.get('S31_OWNED_SYSTEMD_FIXTURE') == 'yes'
        assert Path('/proc/1/comm').read_text().strip() == 'systemd'
        self.workspace = Path.cwd().resolve(strict=True)
        assert self.workspace == Path(os.environ['GITHUB_WORKSPACE']).resolve(strict=True)
        assert str(self.workspace).startswith('/home/runner/work/')
        self.package = Path(os.environ['S31_PACKAGE_ROOT']).resolve(strict=True)
        assert self.package.is_relative_to(Path(os.environ['RUNNER_TEMP']).resolve(strict=True))
        self.manifest = json.loads((self.package / 'PACKAGE_MANIFEST.json').read_text())
        self.source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        assert self.manifest['source_commit'] == self.source
        self.files = {r['path']: r for r in self.manifest['files']}
        assert digest(Path(__file__).read_bytes()) == self.files['tools/sprint31/systemd-profile-ci.py']['sha256']
        package_check = json.loads((self.workspace / 'systemd-package-verification.json').read_text())
        assert package_check['status'] == 'S30_DOWNLOADED_LINUX_PACKAGE_PASS' and package_check['source_commit'] == self.source
        self.package_archive_sha = package_check['archive_sha256']
        self.output = self.workspace / '.local/sprint31/systemd'
        assert not self.output.exists() and self.output.parent.resolve().is_relative_to(self.workspace)
        self.output.mkdir(parents=True, mode=0o700)
        self.commands, self.requests, self.cases = [], [], []
        self.installed_files = {}
        self.installed, self.firewalls = [], []
        self.chain = 'PI_S31_SYSTEMD'
        self.container = os.environ['POSTGRES_CONTAINER']
        assert re.fullmatch('[0-9a-f]{12,64}', self.container)
        self.password = secrets.token_urlsafe(32)
        self.owner_password = secrets.token_urlsafe(32)
        self.viewer_password = secrets.token_urlsafe(32)
        self.database_url = 'postgresql://pi_s31_app:' + self.password + '@127.0.0.1:55449/pi_s31_service_ci?connect_timeout=5'

    def call(self, label, args, data=None, timeout=30, allowed=(0,)):
        completed = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
        assert len(completed.stdout) <= 2 * 1024 * 1024 and len(completed.stderr) <= 2 * 1024 * 1024
        prefix = f'{len(self.commands):03}-{label}'
        (self.output / (prefix + '.stdout')).write_bytes(completed.stdout)
        (self.output / (prefix + '.stderr')).write_bytes(completed.stderr)
        self.commands.append(dict(label=label, program=Path(args[0]).name, native_exit=completed.returncode,
                                  stdout_sha256=digest(completed.stdout), stderr_sha256=digest(completed.stderr)))
        assert completed.returncode in allowed, f'command failed: {label}, exit {completed.returncode}'
        return completed

    def check(self, name, condition):
        assert condition, name
        self.cases.append(dict(case=name, outcome='pass'))

    def admin(self, label, sql):
        result = self.call(label, ['docker', 'exec', '-i', self.container, 'psql', '-X', '-qAt',
            '-U', 'pi_s31_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], sql.encode())
        return result.stdout.decode().strip()

    def preflight(self):
        self.call('sudo-available', ['sudo', '-n', 'true'])
        for value in TARGETS:
            path = Path(value)
            assert not path.exists() and not path.is_symlink(), 'preexisting install target: ' + value
            assert str(path.resolve()) == value
        for name in ['process-intelligence', 'caddy']:
            for lookup in [pwd.getpwnam, grp.getgrnam]:
                try:
                    lookup(name)
                except KeyError:
                    pass
                else:
                    raise AssertionError('preexisting Unix identity: ' + name)
        for unit in [APP, PROXY]:
            result = self.call('unit-absent', ['systemctl', 'show', unit, '-p', 'LoadState', '--value'], allowed=(0, 1))
            assert result.stdout.strip() == b'not-found'
        for port in [3000, 8080, 8443]:
            with socket.socket() as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(('127.0.0.1', port))
                sock.listen(1)
            with socket.socket(socket.AF_INET6) as sock:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(('::1', port))
                sock.listen(1)
        container = json.loads(self.call('container-identity', ['docker', 'inspect', self.container]).stdout)[0]
        assert container['Config']['Image'] == 'postgres:18.0' and container['State']['Running'] is True
        assert container['HostConfig']['PortBindings']['5432/tcp'] == [{'HostIp': '127.0.0.1', 'HostPort': '55449'}]
        assert container['NetworkSettings']['Ports']['5432/tcp'] == [{'HostIp': '127.0.0.1', 'HostPort': '55449'}]
        self.container_image = container['Image']
        assert self.admin('postgres-version', 'SHOW server_version_num;').startswith('18')
        assert self.admin('role-absent', "SELECT count(*) FROM pg_roles WHERE rolname='pi_s31_app';") == '0'
        assert self.admin('database-absent', "SELECT count(*) FROM pg_database WHERE datname='pi_s31_service_ci';") == '0'
        for program in ['iptables', 'ip6tables']:
            existing = self.call('firewall-absent', ['sudo', program, '-S', self.chain], allowed=(0, 1))
            assert existing.returncode == 1
        self.check('fresh_host_paths_users_units_and_listener_ports', True)
        self.check('postgres18_container_has_owned_loopback_55449_mapping', True)

    def install(self):
        for program in ['iptables', 'ip6tables']:
            self.call('firewall-create', ['sudo', program, '-N', self.chain])
            state = dict(program=program, attached=False)
            self.firewalls.append(state)
            self.call('firewall-tcp', ['sudo', program, '-A', self.chain, '!', '-i', 'lo', '-p', 'tcp', '-m', 'multiport', '--dports', '8080,8443', '-j', 'REJECT', '--reject-with', 'tcp-reset'])
            self.call('firewall-udp', ['sudo', program, '-A', self.chain, '!', '-i', 'lo', '-p', 'udp', '--dport', '8443', '-j', 'REJECT'])
            self.call('firewall-return', ['sudo', program, '-A', self.chain, '-j', 'RETURN'])
            self.call('firewall-attach', ['sudo', program, '-I', 'INPUT', '1', '-j', self.chain])
            state['attached'] = True
        self.admin('create-role', "CREATE ROLE pi_s31_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '" + self.password + "';")
        self.admin('create-database', 'CREATE DATABASE pi_s31_service_ci OWNER pi_s31_app;')
        self.admin('deny-other-database', 'REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;')
        role = json.loads(self.admin('role-policy', "SELECT json_build_object('superuser',rolsuper,'createdb',rolcreatedb,'createrole',rolcreaterole) FROM pg_roles WHERE rolname='pi_s31_app';"))
        self.check('application_database_role_is_not_cluster_administrator', role == dict(superuser=False, createdb=False, createrole=False))
        self.call('download-caddy', ['curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '90', CADDY_ARCHIVE, '--output', str(self.output / 'caddy.tar.gz')], timeout=100)
        assert digest((self.output / 'caddy.tar.gz').read_bytes()) == CADDY_ARCHIVE_SHA
        with tarfile.open(self.output / 'caddy.tar.gz', 'r:gz') as archive:
            member = archive.getmember('caddy')
            assert member.isfile() and member.size <= 64 * 1024 * 1024
            (self.output / 'caddy').write_bytes(archive.extractfile(member).read())
        self.caddy_sha = digest((self.output / 'caddy').read_bytes())
        self.call('vendor-unit', ['curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '30', VENDOR_UNIT, '--output', str(self.output / 'caddy.service')], timeout=35)
        assert digest((self.output / 'caddy.service').read_bytes()) == VENDOR_UNIT_SHA
        self.call('create-app-user', ['sudo', 'useradd', '--system', '--user-group', '--no-create-home', '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin', 'process-intelligence'])
        self.call('create-proxy-user', ['sudo', 'useradd', '--system', '--user-group', '--create-home', '--home-dir', '/var/lib/caddy', '--shell', '/usr/sbin/nologin', 'caddy'])
        self.call('install-directories', ['sudo', 'install', '-d', '-m', '0755', '/opt/process-intelligence/current', '/etc/process-intelligence', '/etc/caddy', '/etc/systemd/system/caddy.service.d'])
        self.call('proxy-private-directories', ['sudo', 'install', '-d', '-m', '0750', '-o', 'caddy', '-g', 'caddy', '/var/log/caddy'])
        self.call('certificate-directory', ['sudo', 'install', '-d', '-m', '0750', '-o', 'root', '-g', 'caddy', '/etc/process-intelligence/tls'])
        self.call('install-package', ['sudo', 'cp', '-a', '--no-preserve=ownership', str(self.package) + '/.', '/opt/process-intelligence/current/'])
        assert self.call('installed-app-owner', ['sudo', 'stat', '-c', '%U:%G', '/opt/process-intelligence/current/process-intelligence-rs']).stdout.strip() == b'root:root'
        self.call('install-proxy', ['sudo', 'install', '-m', '0755', str(self.output / 'caddy'), '/usr/bin/caddy'])
        for source, target in [('deploy/linux/process-intelligence.service', '/etc/systemd/system/' + APP),
                               ('deploy/linux/Caddyfile', '/etc/caddy/Caddyfile'),
                               ('deploy/linux/caddy-process-intelligence.conf', '/etc/systemd/system/caddy.service.d/process-intelligence.conf')]:
            assert digest((self.package / source).read_bytes()) == self.files[source]['sha256']
            self.call('install-profile-file', ['sudo', 'install', '-m', '0644', str(self.package / source), target])
            observed_sha = self.call('installed-profile-sha', ['sudo', 'sha256sum', target]).stdout.decode().split()[0]
            assert observed_sha == self.files[source]['sha256']
            self.installed_files[source] = dict(path=target, sha256=observed_sha)
        self.installed.append(APP)
        self.call('install-proxy-unit', ['sudo', 'install', '-m', '0644', str(self.output / 'caddy.service'), '/etc/systemd/system/' + PROXY])
        assert self.call('installed-vendor-sha', ['sudo', 'sha256sum', '/etc/systemd/system/' + PROXY]).stdout.decode().split()[0] == VENDOR_UNIT_SHA
        self.installed.append(PROXY)
        self.call('ca', ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(self.output / 'ca.key'), '-out', str(self.output / 'ca.pem'), '-subj', '/CN=Sprint31 ephemeral CI CA', '-days', '2'])
        self.call('leaf-request', ['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(self.output / 'server.key'), '-out', str(self.output / 'server.csr'), '-subj', '/CN=localhost'])
        (self.output / 'server.ext').write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n')
        self.call('leaf-certificate', ['openssl', 'x509', '-req', '-in', str(self.output / 'server.csr'), '-CA', str(self.output / 'ca.pem'), '-CAkey', str(self.output / 'ca.key'), '-CAcreateserial', '-out', str(self.output / 'server.pem'), '-days', '2', '-extfile', str(self.output / 'server.ext')])
        for name, content in [('database-url', self.database_url + '\n'), ('app-environment', 'PI_PUBLIC_ORIGIN=' + ORIGIN + '\n'),
                              ('caddy-environment', 'PI_TLS_HOST=localhost\nPI_HTTPS_PORT=8443\nPI_HTTP_PORT=8080\nPI_BACKEND_PORT=3000\nPI_TLS_CERT=/etc/process-intelligence/tls/server.pem\nPI_TLS_KEY=/etc/process-intelligence/tls/server.key\n')]:
            (self.output / name).write_text(content)
            self.call('install-private-configuration', ['sudo', 'install', '-m', '0600', str(self.output / name), '/etc/process-intelligence/' + name])
        for name in ['server.pem', 'server.key']:
            self.call('install-leaf', ['sudo', 'install', '-m', '0640', '-o', 'root', '-g', 'caddy', str(self.output / name), '/etc/process-intelligence/tls/' + name])
        self.call('credential-permissions', ['sudo', '-u', 'process-intelligence', 'test', '!', '-r', '/etc/process-intelligence/database-url'])
        self.check('credential_source_root0600_not_directly_readable_by_app_user', self.call('credential-stat', ['sudo', 'stat', '-c', '%a:%U:%G', '/etc/process-intelligence/database-url']).stdout.strip() == b'600:root:root')
        self.call('manager-reload', ['sudo', 'systemctl', 'daemon-reload'])
        self.call('start-app', ['sudo', 'systemctl', 'start', APP], timeout=60)
        self.call('start-proxy', ['sudo', 'systemctl', 'start', PROXY], timeout=30)
        self.client = Client(self.output / 'ca.pem', self.requests)
        self.health()

    def health(self):
        until = time.monotonic() + 25
        while True:
            try:
                code, raw = self.client.request('GET', '/health')
                if code == 200:
                    value = json.loads(raw)
                    assert value['status'] == 'ready'
                    assert value['version'] == tomllib.loads(Path('Cargo.toml').read_text())['package']['version']
                    return
                assert code in (502, 503), 'unexpected health status'
                assert time.monotonic() < until, 'service did not become ready'
                time.sleep(.1)
            except urllib.error.URLError:
                if time.monotonic() >= until:
                    raise
                time.sleep(.1)

    def identity(self, unit, stopped=False):
        names = ['ActiveState', 'MainPID', 'ExecMainStartTimestampMonotonic', 'User', 'Group', 'NRestarts', 'Result', 'ExecMainStatus', 'NoNewPrivileges', 'ProtectSystem', 'FragmentPath', 'DropInPaths', 'WorkingDirectory']
        result = self.call('unit-identity', ['systemctl', 'show', unit] + ['--property=' + key for key in names]).stdout.decode()
        properties = dict(line.split('=', 1) for line in result.splitlines() if '=' in line)
        assert properties['FragmentPath'] == '/etc/systemd/system/' + unit
        assert properties['DropInPaths'] == ('' if unit == APP else '/etc/systemd/system/caddy.service.d/process-intelligence.conf')
        assert properties['NRestarts'] == '0' and properties['Result'] == 'success' and properties['ExecMainStatus'] == '0'
        if stopped:
            assert properties['ActiveState'] == 'inactive' and properties['MainPID'] == '0'
            return properties
        assert properties['ActiveState'] == 'active' and int(properties['MainPID']) > 1
        pid = properties['MainPID']
        expected_sha = self.files['process-intelligence-rs']['sha256'] if unit == APP else self.caddy_sha
        executable_sha = self.call('running-executable', ['sudo', 'sha256sum', '/proc/' + pid + '/exe']).stdout.decode().split()[0]
        assert executable_sha == expected_sha
        status = self.call('running-user', ['sudo', 'cat', '/proc/' + pid + '/status']).stdout.decode()
        expected_user = 'process-intelligence' if unit == APP else 'caddy'
        assert properties['User'] == properties['Group'] == expected_user
        assert int(re.search(r'^Uid:\s+(\d+)', status, re.M)[1]) == pwd.getpwnam(expected_user).pw_uid > 0
        args = self.call('running-arguments', ['sudo', 'cat', '/proc/' + pid + '/cmdline']).stdout.split(b'\0')[:-1]
        if unit == APP:
            assert properties['NoNewPrivileges'] == 'yes' and properties['ProtectSystem'] == 'strict'
            assert properties['WorkingDirectory'] == '/opt/process-intelligence/current'
            assert re.search(r'^NoNewPrivs:\s+1$', status, re.M)
            assert args == [b'/opt/process-intelligence/current/process-intelligence-rs']
            environment = self.call('credential-environment', ['sudo', 'cat', '/proc/' + pid + '/environ']).stdout
            env = dict(item.split(b'=', 1) for item in environment.split(b'\0') if b'=' in item)
            assert b'PI_DATABASE_URL' not in env and env[b'PI_DATABASE_URL_FILE'].startswith(b'/run/credentials/')
            assert self.database_url.encode() not in environment
        else:
            assert args == [b'/usr/bin/caddy', b'run', b'--config', b'/etc/caddy/Caddyfile', b'--adapter', b'caddyfile']
        properties['executable_sha256'] = executable_sha
        return properties

    def upload(self, path, filename, raw, fields=None):
        boundary = 's31-profile-fixture'
        body = bytearray()
        for key, value in (fields or {}).items():
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode())
        body.extend(raw)
        body.extend(f'\r\n--{boundary}--\r\n'.encode())
        code, _ = self.client.request('POST', path, bytes(body), 'multipart/form-data; boundary=' + boundary)
        assert code in (200, 303), 'fixture import failed'

    def backup(self):
        code, raw = self.client.request('GET', '/backup')
        assert code == 200
        value = json.loads(raw)
        assert set(value) == {'schema_version', 'source_project_id', 'payload', 'digest_sha256'} and value['schema_version'] == 1
        encoded = json.dumps(value['payload'], ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
        assert digest(encoded) == value['digest_sha256']
        return raw, value

    def accounting(self, project):
        assert re.fullmatch('project-[0-9a-f]{32}', project)
        sql = "SELECT jsonb_build_object('quota',(SELECT to_jsonb(q) FROM public.pi_project_quota q WHERE project_id='" + project + "'),'records',(SELECT jsonb_agg(jsonb_build_array(kind,resource_id,version,encode(sha256(convert_to(document::text,'UTF8')),'hex')) ORDER BY kind,resource_id) FROM public.pi_records WHERE project_id='" + project + "'),'policy',(SELECT document->'quota_policy' FROM public.pi_projects WHERE project_id='" + project + "'));"
        result = self.call('accounting-snapshot', ['docker', 'exec', '-i', self.container, 'psql', '-X', '-qAt', '-U', 'pi_s31_admin', '-d', 'pi_s31_service_ci', '-v', 'ON_ERROR_STOP=1'], sql.encode())
        return json.loads(result.stdout)

    def exercise(self):
        self.before_app, self.before_proxy = self.identity(APP), self.identity(PROXY)
        self.check('downloaded_app_and_delivered_units_are_the_running_processes', True)
        self.check('systemd_LoadCredential_and_actual_NoNewPrivs_without_URL_in_environment', True)
        code, _ = self.client.request('POST', '/setup', dict(username='s31_owner', password=self.owner_password))
        assert code == 303 and bool(list(self.client.jar)) and all(cookie.secure for cookie in self.client.jar)
        self.upload('/logs', 'service.xes', b'<log><trace><string key="concept:name" value="service"/><event><string key="concept:name" value="A"/></event><event><string key="concept:name" value="B"/></event><event><string key="concept:name" value="C"/></event></trace></log>')
        self.upload('/models/import', 'service.bpmn', (self.package / 'fixtures/quality/linear.bpmn').read_bytes(), dict(name='Systemd saved BPMN'))
        _, bundle = self.backup()
        logs, models = bundle['payload']['logs'], bundle['payload']['models']
        assert len(logs) == len(models) == 1
        log, model = next(iter(logs)), next(iter(models))
        action = '/models/' + model + '/quality/jobs'
        code, raw = self.client.request('GET', '/models/' + model + '/quality/new')
        assert code == 200
        form = SubmissionForm(action)
        form.feed(raw.decode())
        assert set(form.fields) == {'revision', 'request_key'} and int(form.fields['revision']) == models[model]['revision']
        code, raw = self.client.request('POST', action, dict(form.fields, log_id=log))
        assert code == 202
        self.job = json.loads(raw)['snapshot']['id']
        until = time.monotonic() + 30
        while True:
            meta = self.client.get('/quality/jobs/' + self.job)
            if meta['snapshot']['state'] in ['completed', 'failed', 'cancelled']:
                assert meta['snapshot']['state'] == 'completed'
                break
            assert time.monotonic() < until
            time.sleep(.1)
        self.report_path = '/quality/jobs/' + self.job + '/report'
        code, self.report = self.client.request('GET', self.report_path)
        assert code == 200
        (self.output / 'saved-report.json').write_bytes(self.report)
        replay = json.loads(self.call('numeric-report', ['/opt/process-intelligence/current/process-intelligence-rs', '--verify-quality-report', str(self.output / 'saved-report.json')]).stdout)
        assert replay['status'] == 'quality_report_verified' and replay['numeric_replay'] is True and replay['author_signature_verified'] is False
        exported = json.loads(self.report)
        assert replay['method_sha256'] == exported['method_sha256']
        assert replay['input_model_sha256'] == exported['evaluation']['input_model_sha256']
        assert replay['input_variants_sha256'] == exported['evaluation']['input_variants_sha256']
        self.numeric_replay = replay
        quota = self.client.get('/quota/status')
        assert self.client.request('POST', '/quota', dict(revision=quota['revision'], mode='enabled', payload_allowance=0))[0] == 303
        self.check('release_service_publishes_and_numerically_verifies_saved_quality_report', True)
        assert self.client.request('POST', '/users', dict(username='s31_viewer', password=self.viewer_password))[0] == 303
        _, bundle = self.backup()
        self.project = bundle['source_project_id']
        assert self.client.request('POST', '/projects/' + self.project + '/members', dict(username='s31_viewer', role='viewer'))[0] == 303
        viewer = Client(self.output / 'ca.pem', self.requests)
        assert viewer.request('POST', '/login', dict(username='s31_viewer', password=self.viewer_password))[0] == 303
        assert viewer.request('POST', '/projects/' + self.project + '/open', {})[0] == 303
        assert viewer.request('GET', self.report_path) == (200, self.report)
        assert viewer.request('POST', '/quota', dict(revision=0, mode='disabled', payload_allowance=0))[0] == 403
        self.check('grant_and_viewer_reads_remain_available_while_over_quota', True)
        self.quota = self.client.get('/quota/status')
        assert self.quota['enabled'] is True and self.quota['payload_allowance'] == 0 and self.quota['payload_used'] > 0
        self.backup_before, _ = self.backup()
        self.accounting_before = self.accounting(self.project)
        cookie_secrets = {cookie.value for client in [self.client, viewer] for cookie in client.jar}
        started = time.monotonic()
        self.call('restart-app', ['sudo', 'systemctl', 'restart', APP], timeout=60)
        assert time.monotonic() - started < 40, 'restart approached forced-stop timeout'
        self.health()
        self.after_app = self.identity(APP)
        assert self.after_app['MainPID'] != self.before_app['MainPID']
        assert int(self.after_app['ExecMainStartTimestampMonotonic']) > int(self.before_app['ExecMainStartTimestampMonotonic'])
        self.client = Client(self.output / 'ca.pem', self.requests)
        assert self.client.request('POST', '/login', dict(username='s31_owner', password=self.owner_password))[0] == 303
        assert self.client.get('/quota/status') == self.quota
        assert self.client.request('GET', self.report_path) == (200, self.report)
        assert self.backup()[0] == self.backup_before
        assert self.accounting(self.project) == self.accounting_before
        self.check('systemctl_restart_changes_app_process_and_preserves_quota_backup_report_and_ledger', True)
        viewer_after = Client(self.output / 'ca.pem', self.requests)
        assert viewer_after.request('POST', '/login', dict(username='s31_viewer', password=self.viewer_password))[0] == 303
        assert viewer_after.request('POST', '/projects/' + self.project + '/open', {})[0] == 303
        assert viewer_after.request('GET', self.report_path) == (200, self.report)
        assert viewer_after.request('POST', '/quota', dict(revision=0, mode='disabled', payload_allowance=0))[0] == 403
        self.check('viewer_grant_and_write_refusal_survive_application_restart', True)
        self.call('restart-proxy', ['sudo', 'systemctl', 'restart', PROXY], timeout=15)
        self.health()
        self.after_proxy = self.identity(PROXY)
        assert self.after_proxy['MainPID'] != self.before_proxy['MainPID']
        assert int(self.after_proxy['ExecMainStartTimestampMonotonic']) > int(self.before_proxy['ExecMainStartTimestampMonotonic'])
        assert self.identity(APP)['MainPID'] == self.after_app['MainPID']
        code, raw = self.client.request('GET', '/quality/jobs/' + self.job + '/events')
        assert code == 200 and b'datastar-patch-elements' in raw and self.job.encode() in raw
        assert self.client.request('GET', self.report_path) == (200, self.report)
        assert self.accounting(self.project) == self.accounting_before
        self.check('proxy_service_restart_keeps_app_and_allows_new_terminal_SSE_connection', True)
        journal = self.call('private-journal', ['sudo', 'journalctl', '-u', APP, '-u', PROXY, '--no-pager', '-o', 'json', '-n', '150']).stdout
        assert all(secret.encode() not in journal for secret in [self.database_url, self.password, self.owner_password, self.viewer_password])
        cookie_secrets.update(cookie.value for client in [self.client, viewer_after] for cookie in client.jar)
        assert all(secret.encode() not in journal for secret in cookie_secrets)
        assert b'BEGIN PRIVATE KEY' not in journal
        self.check('fixture_credentials_and_private_keys_not_in_unit_journals', True)
        self.call('stop-proxy', ['sudo', 'systemctl', 'stop', PROXY], timeout=15)
        self.stop_proxy = self.identity(PROXY, stopped=True)
        self.call('stop-app', ['sudo', 'systemctl', 'stop', APP], timeout=60)
        self.stop_app = self.identity(APP, stopped=True)
        self.check('both_owned_units_stop_inactive_with_zero_main_pid_and_successful_exit', True)

    def cleanup(self):
        errors = []
        for unit in reversed(self.installed):
            try:
                self.call('cleanup-stop', ['sudo', 'systemctl', 'stop', unit], timeout=60)
                state = self.call('cleanup-state', ['systemctl', 'show', unit, '-p', 'ActiveState', '-p', 'MainPID']).stdout.decode()
                assert 'ActiveState=inactive' in state and 'MainPID=0' in state
            except Exception:
                errors.append('stop:' + unit)
        if not errors:
            for state in reversed(self.firewalls):
                operations = ([['-D', 'INPUT', '-j', self.chain]] if state['attached'] else []) + [['-F', self.chain], ['-X', self.chain]]
                for args in operations:
                    try:
                        self.call('cleanup-firewall', ['sudo', state['program']] + args)
                    except Exception:
                        errors.append('firewall:' + state['program'])
        assert not errors, 'owned fixture cleanup failed: ' + ','.join(errors)

    def proof(self):
        return dict(status='S31_SYSTEMD_RELEASE_PROFILE_PASS', source_commit=self.source,
            package_archive_sha256=self.package_archive_sha, package_manifest_sha256=digest((self.package / 'PACKAGE_MANIFEST.json').read_bytes()),
            installed_profile_files=self.installed_files,
            package_app_sha256=self.files['process-intelligence-rs']['sha256'], vendor_unit_sha256=VENDOR_UNIT_SHA,
            caddy_archive_sha256=CADDY_ARCHIVE_SHA, container_image=self.container_image,
            cases=self.cases, requests=self.requests, commands=self.commands,
            app_before=self.before_app, app_after=self.after_app, proxy_before=self.before_proxy, proxy_after=self.after_proxy,
            app_stopped=self.stop_app, proxy_stopped=self.stop_proxy, quota=self.quota,
            report_sha256=digest(self.report), project_backup_sha256=digest(self.backup_before),
            accounting_sha256=digest(json.dumps(self.accounting_before, sort_keys=True).encode()), numeric_replay=self.numeric_replay,
            global_CA_store_modified=False, scope='fresh GitHub-hosted Ubuntu24.04 VM, exact delivered app unit/Caddyfile/drop-in, vendor proxy unit; Docker PG18 on loopback55449; unit Wants may also start preinstalled OS PostgreSQL5432; no production host, public DNS/CA, VM reboot, OS PostgreSQL qualification, HA/SLA or continuous SSE across restart')


if __name__ == '__main__':
    os.umask(0o077)
    fixture = Fixture()
    failure = None
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        fixture.preflight()
        fixture.install()
        fixture.exercise()
    except BaseException as error:
        failure = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            fixture.cleanup()
        except BaseException as error:
            failure = (failure or '') + '; cleanup: ' + type(error).__name__ + ': ' + str(error)
    if failure:
        (fixture.output / 'failure.json').write_text(json.dumps(dict(status='S31_SYSTEMD_PROFILE_FAILED', failure=failure, cases=fixture.cases, commands=fixture.commands), indent=2) + '\n')
        raise SystemExit('S31_SYSTEMD_PROFILE_FAILED: ' + failure)
    result = fixture.proof()
    (fixture.output / 'proof.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
