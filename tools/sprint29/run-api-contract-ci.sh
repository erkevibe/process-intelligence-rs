#!/usr/bin/env bash
# Ephemeral GitHub Actions fixture only; never an installed-user database.
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
test "${S29_OWNED_FIXTURE:-}" = yes
python3 - <<'PY'
import os, socket, urllib.parse
u = urllib.parse.urlsplit(os.environ['S28_DISCOVERY_DATABASE_URL'])
assert u.scheme == 'postgresql' and u.hostname == '127.0.0.1' and u.port == 5432
assert u.username == 'pi_s21_app' and u.path == '/pi_s28_discovery_core_ci'
with socket.socket() as s:
    s.bind(('127.0.0.1',3147))
PY
mkdir -p .local/sprint29/ci-seed .local/sprint29/ci-api
export PI_DATABASE_URL="$S28_DISCOVERY_DATABASE_URL"
export PORT=3147
target/debug/process-intelligence-rs >.local/sprint29/server.stdout 2>.local/sprint29/server.stderr &
pi_contract_pid=$!
cleanup() {
    kill "$pi_contract_pid" 2>/dev/null || true
    wait "$pi_contract_pid" 2>/dev/null || true
}
trap cleanup EXIT
export S29_SERVER_PID="$pi_contract_pid"
wait_ready() {
python3 - <<'PY'
import json, os, time, urllib.error, urllib.request
client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
end = time.monotonic()+20
while True:
    os.kill(int(os.environ['S29_SERVER_PID']),0)
    try:
        with client.open('http://127.0.0.1:3147/health',timeout=1) as response:
            assert response.status == 200 and json.load(response)['version'] == '0.10.0'
        break
    except urllib.error.URLError:
        if time.monotonic() >= end:
            raise
        time.sleep(0.1)
PY
}
wait_ready
export S28_BASE_URL=http://127.0.0.1:3147
export S28_OWNED_FIXTURE=yes
export S28_HTTP_OUTPUT=.local/sprint29/ci-seed
export S28_HTTP_STATE=.local/sprint29/ci-seed-state.json
timeout 120s python3 -I -B tools/sprint28/discovery-http.py basic
pi_seed_pid="$pi_contract_pid"
kill "$pi_seed_pid"
if wait "$pi_seed_pid"; then
    pi_seed_exit=0
else
    pi_seed_exit=$?
fi
case "$pi_seed_exit" in 0|143) ;; *) exit 1 ;; esac
target/debug/process-intelligence-rs >>.local/sprint29/server.stdout 2>>.local/sprint29/server.stderr &
pi_contract_pid=$!
test "$pi_contract_pid" != "$pi_seed_pid"
export S29_SERVER_PID="$pi_contract_pid"
export S29_SEED_PID="$pi_seed_pid"
wait_ready
python3 - <<'PY'
import json, os
from pathlib import Path
v = dict(status='S29_CI_CONTROLLED_RESTART',seed_pid=int(os.environ['S29_SEED_PID']),probe_pid=int(os.environ['S29_SERVER_PID']))
assert v['seed_pid'] != v['probe_pid']
Path('.local/sprint29/restart.json').write_text(json.dumps(v),encoding='utf-8')
print(json.dumps(v))
PY
export S29_BASE_URL=http://127.0.0.1:3147
export S29_HTTP_OUTPUT=.local/sprint29/ci-api
export S29_SEED_STATE=.local/sprint29/ci-seed-state.json
export S29_SEED_PROOF=.local/sprint29/ci-seed/proof.json
export S29_VIEWER_NAME=s29_api_viewer01
timeout 120s python3 -I -B tools/sprint29/api-contract-probe.py

