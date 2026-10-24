#!/usr/bin/env python3
"""Invalid public origins must fail before touching the fresh owned database."""
import json
import os
from pathlib import Path
import subprocess
import urllib.parse

assert os.environ.get('GITHUB_ACTIONS') == 'true'
url = os.environ['S30_ORIGIN_DATABASE_URL']
parsed = urllib.parse.urlsplit(url)
assert parsed.hostname == '127.0.0.1' and parsed.port == 5432 and parsed.path == '/pi_s30_origin_ci'
assert parsed.username == 'pi_s21_app' and parsed.scheme == 'postgresql'
cases = []
for origin in ['https://example.com/path', 'https://0X7F000001:3148', 'https://0x', 'https://example.0X', 'https://localhost:3148', 'https://[::ffff:127.0.0.1]:8443', 'https://[::ffff:7f00:1]:8443']:
    env = dict(os.environ, PI_DATABASE_URL=url, PI_PUBLIC_ORIGIN=origin, PORT='3148')
    env.pop('PI_DATABASE_URL_FILE', None)
    result = subprocess.run(['target/debug/process-intelligence-rs'], env=env, capture_output=True, timeout=5)
    assert result.returncode == 1 and b'PI_PUBLIC_ORIGIN' in result.stderr
    cases.append(dict(origin=origin, native_exit=result.returncode))
query = subprocess.run(['docker', 'exec', os.environ['POSTGRES_CONTAINER'], 'psql', '-X', '-qAt',
    '-U', 'pi_s21_app', '-d', 'pi_s30_origin_ci', '-v', 'ON_ERROR_STOP=1', '-c',
    "SELECT count(*) FROM pg_tables WHERE schemaname='public';"], capture_output=True, check=True, timeout=15)
assert query.stdout.strip() == b'0', 'invalid configuration touched database'
proof = dict(status='S30_INVALID_ORIGIN_BEFORE_DATABASE_PASS', cases=cases, public_tables=0)
output = Path('.local/sprint30')
output.mkdir(parents=True, exist_ok=True)
(output / 'origin-startup-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
print(json.dumps(proof))
