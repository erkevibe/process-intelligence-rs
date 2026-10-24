#!/usr/bin/env bash
# Owned, disposable CI databases only; credential-bearing dump stays private.
set -euo pipefail
umask 077
test "${GITHUB_ACTIONS:-}" = true
test "${S30_OWNED_QUOTA_DR:-}" = yes
python3 - <<'PY'
import os, urllib.parse
u=urllib.parse.urlsplit(os.environ['S28_DISCOVERY_DATABASE_URL'])
assert u.scheme=='postgresql' and u.hostname=='127.0.0.1' and u.port==5432
assert u.username=='pi_s21_app' and u.path=='/pi_s28_discovery_core_ci'
PY
out="$PWD/.local/sprint30/ci-dr"
test ! -e "$out"
mkdir -p "$out"
export S30_DR_OUTPUT="$out"
unset PI_DATABASE_URL_FILE PI_PUBLIC_ORIGIN
export PI_DATABASE_URL="$S28_DISCOVERY_DATABASE_URL" PORT=3147
app_pid=''
stop_app() {
    if test -n "$app_pid"; then kill -INT "$app_pid"; wait "$app_pid"; app_pid=''; fi
}
trap 'if test -n "$app_pid"; then kill -INT "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi' EXIT
start_app() {
    target/debug/process-intelligence-rs >> "$out/app.stdout" 2>> "$out/app.stderr" &
    app_pid=$!
    export S30_APP_PID="$app_pid"
    python3 - <<'PY'
import json,os,time,urllib.request,urllib.error
c=urllib.request.build_opener(urllib.request.ProxyHandler({}))
end=time.monotonic()+25
while True:
    os.kill(int(os.environ['S30_APP_PID']),0)
    try:
        with c.open('http://127.0.0.1:3147/health',timeout=1) as r:
            assert r.status==200 and json.load(r)['status']=='ready'
        break
    except urllib.error.URLError:
        if time.monotonic()>=end: raise
        time.sleep(.1)
PY
}
start_app
python3 -I -B tools/sprint30/quota-dr-probe.py before
stop_app
docker exec -i "$POSTGRES_CONTAINER" psql -X -qAt -U pi_s21_app -d pi_s28_discovery_core_ci -v ON_ERROR_STOP=1 < tools/sprint30/storage-snapshot.sql > "$out/before-storage.json"
docker exec "$POSTGRES_CONTAINER" pg_dump -U pi_s21_app -d pi_s28_discovery_core_ci -Fc > "$out/database.dump"
docker exec "$POSTGRES_CONTAINER" psql -U pi_s21_app -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE pi_s30_quota_dr_ci OWNER pi_s21_app;'
docker exec -i "$POSTGRES_CONTAINER" pg_restore -U pi_s21_app -d pi_s30_quota_dr_ci --exit-on-error --single-transaction < "$out/database.dump"
docker exec -i "$POSTGRES_CONTAINER" psql -X -qAt -U pi_s21_app -d pi_s30_quota_dr_ci -v ON_ERROR_STOP=1 < tools/sprint30/storage-snapshot.sql > "$out/after-storage.json"
cmp "$out/before-storage.json" "$out/after-storage.json"
export PI_DATABASE_URL="${S28_DISCOVERY_DATABASE_URL/pi_s28_discovery_core_ci/pi_s30_quota_dr_ci}"
start_app
python3 -I -B tools/sprint30/quota-dr-probe.py after
stop_app
target/debug/process-intelligence-rs --verify-quality-report "$out/after-report.json" > "$out/report-verification.json"
python3 - <<'PY'
import hashlib,json,os
from pathlib import Path
p=Path(os.environ['S30_DR_OUTPUT'])
v=json.loads((p/'after.json').read_text())
replay=json.loads((p/'report-verification.json').read_text())
report=json.loads((p/'after-report.json').read_text())
assert replay['status']=='quality_report_verified' and replay['numeric_replay'] is True and replay['author_signature_verified'] is False
assert replay['method_sha256']==report['method_sha256']
assert replay['input_model_sha256']==report['evaluation']['input_model_sha256']
assert replay['input_variants_sha256']==report['evaluation']['input_variants_sha256']
v['cases'].append('restored_quality_report_numeric_replay_verified')
v['cases'].append('full_storage_snapshot_equal_before_restored_login')
v['storage_snapshot_sha256']=hashlib.sha256((p/'before-storage.json').read_bytes()).hexdigest()
v['dump_sha256']=hashlib.sha256((p/'database.dump').read_bytes()).hexdigest()
v['dump_published']=False
(p/'proof.json').write_text(json.dumps(v,indent=2)+'\n')
print(json.dumps(v))
PY
