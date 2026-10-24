#!/usr/bin/env bash
# Disposable CI database/ports only. Does not install services or trust a CA globally.
set -euo pipefail
umask 077
test "${GITHUB_ACTIONS:-}" = true
test "${S30_OWNED_TLS_FIXTURE:-}" = yes
python3 - <<'PY'
import os,socket,urllib.parse
u=urllib.parse.urlsplit(os.environ['S28_DISCOVERY_DATABASE_URL'])
assert u.scheme=='postgresql' and u.hostname=='127.0.0.1' and u.port==5432
assert u.username=='pi_s21_app' and u.path=='/pi_s28_discovery_core_ci'
for port in (3147,8080,8443):
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        s.bind(('127.0.0.1',port))
        s.listen(1)
PY
out="$PWD/.local/sprint30/ci-tls"
test ! -e "$out"
mkdir -p "$out"
export S30_TLS_OUTPUT="$out"
curl --fail --silent --show-error --location --max-time 90 \
    https://github.com/caddyserver/caddy/releases/download/v2.11.7/caddy_2.11.7_linux_amd64.tar.gz \
    --output "$out/caddy.tar.gz"
echo "727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b  $out/caddy.tar.gz" | sha256sum --check --strict
tar -xzf "$out/caddy.tar.gz" -C "$out" caddy
"$out/caddy" version > "$out/caddy-version.txt"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/ca.key" -out "$out/ca.pem" \
    -subj '/CN=ProcessMining ephemeral CI CA' -days 2 > "$out/ca.stdout" 2> "$out/ca.stderr"
openssl req -newkey rsa:2048 -nodes -keyout "$out/server.key" -out "$out/server.csr" \
    -subj '/CN=localhost' > "$out/csr.stdout" 2> "$out/csr.stderr"
cat > "$out/server.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
EOF
openssl x509 -req -in "$out/server.csr" -CA "$out/ca.pem" -CAkey "$out/ca.key" \
    -CAcreateserial -out "$out/server.pem" -days 2 -extfile "$out/server.ext" \
    > "$out/certificate.stdout" 2> "$out/certificate.stderr"
printf '%s\n' "$S28_DISCOVERY_DATABASE_URL" > "$out/database-url"
unset PI_DATABASE_URL
export PI_DATABASE_URL_FILE="$out/database-url" PORT=3147
export PI_PUBLIC_ORIGIN=https://localhost:8443
export PI_TLS_HOST=localhost PI_TLS_CERT="$out/server.pem" PI_TLS_KEY="$out/server.key"
export PI_BACKEND_PORT=3147 PI_HTTP_PORT=8080 PI_HTTPS_PORT=8443
"$out/caddy" validate --config deploy/linux/Caddyfile --adapter caddyfile \
    > "$out/caddy-validate.stdout" 2> "$out/caddy-validate.stderr"
app_pid=''
caddy_pid=''
cleanup() {
    if test -n "$caddy_pid"; then kill "$caddy_pid" 2>/dev/null || true; wait "$caddy_pid" 2>/dev/null || true; fi
    if test -n "$app_pid"; then kill -INT "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
target/debug/process-intelligence-rs > "$out/app.stdout" 2> "$out/app.stderr" &
app_pid=$!
"$out/caddy" run --config deploy/linux/Caddyfile --adapter caddyfile \
    > "$out/caddy.stdout" 2> "$out/caddy.stderr" &
caddy_pid=$!
export S30_APP_PID="$app_pid" S30_CADDY_PID="$caddy_pid"
python3 - <<'PY'
import json,os,ssl,time,urllib.error,urllib.request
context=ssl.create_default_context(cafile=os.path.join(os.environ['S30_TLS_OUTPUT'],'ca.pem'))
client=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=context))
end=time.monotonic()+25
while True:
    os.kill(int(os.environ['S30_APP_PID']),0);os.kill(int(os.environ['S30_CADDY_PID']),0)
    try:
        with client.open('https://localhost:8443/health',timeout=1) as r:
            assert r.status==200 and json.load(r)['status']=='ready'
        break
    except urllib.error.URLError:
        if time.monotonic()>=end:raise
        time.sleep(.1)
PY
export S30_SEED_STATE="$PWD/.local/sprint29/ci-seed-state.json"
timeout 120s python3 -I -B tools/sprint30/tls-probe.py
# Validate the delivered unit syntax on Linux; this is not a systemd boot/runtime claim.
systemd-analyze verify deploy/linux/process-intelligence.service 2> "$out/unit-verify.stderr" || {
    # The installed binary path is intentionally absent from the ephemeral runner.
    python3 - <<'PY'
import os
from pathlib import Path
lines=Path(os.environ['S30_TLS_OUTPUT'],'unit-verify.stderr').read_text().splitlines()
assert lines and all('is not executable: No such file or directory' in s for s in lines), lines
PY
}
python3 - <<'PY'
import hashlib,json,os
from pathlib import Path
root=Path(os.environ['S30_TLS_OUTPUT'])
value=dict(status='S30_LINUX_TLS_RUN_COMPLETE',caddy_version=(root/'caddy-version.txt').read_text().strip(),
    config_sha256=hashlib.sha256(Path('deploy/linux/Caddyfile').read_bytes()).hexdigest(),
    app_sha256=hashlib.sha256(Path('target/debug/process-intelligence-rs').read_bytes()).hexdigest(),
    public_origin=os.environ['PI_PUBLIC_ORIGIN'],
    app_pid=int(os.environ['S30_APP_PID']),caddy_pid=int(os.environ['S30_CADDY_PID']),
    private_credential_file_used=True,global_ca_store_modified=False)
(root/'runner-proof.json').write_text(json.dumps(value,indent=2)+'\n')
print(json.dumps(value))
PY
