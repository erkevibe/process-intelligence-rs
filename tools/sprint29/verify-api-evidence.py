#!/usr/bin/env python3
"""Verify saved synthetic API evidence; this does not execute an HTTP probe."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys


def need(value, reason):
    if not value:
        raise ValueError(reason)


def unique(items):
    result = {}
    for key,value in items:
        need(key not in result, 'duplicate JSON key')
        result[key] = value
    return result


def read(raw):
    return json.loads(raw.decode('utf-8-sig'),object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value,ensure_ascii=False,allow_nan=False,sort_keys=True,separators=(',',':')).encode()


def verify(root):
    root = Path(root).resolve(strict=True)
    manifest = read((root/'manifest.json').read_bytes())
    need(manifest['schema_version'] == 1 and len(manifest['files']) == 5, 'manifest coverage')
    files = {}
    for entry in manifest['files']:
        name = entry['path']
        need(type(name) is str and re.fullmatch('[a-z0-9][a-z0-9._-]*',name) and name not in files, 'manifest path')
        path = root/name
        need(path.is_file() and not path.is_symlink(), 'regular evidence file')
        raw = path.read_bytes()
        need(type(entry['bytes']) is int and entry['bytes'] == len(raw) <= 2*1024*1024 and digest(raw) == entry['sha256'], 'manifest bytes/hash')
        files[name] = raw
    need({p.name for p in root.iterdir()} == set(files)|{'manifest.json'}, 'unlisted package content')
    api = read(files['api-proof.json'])
    native = read(files['native-proof.json'])
    review = read(files['independent-review.json'])
    backup = read(files['fixture-backup.json'])
    quality = read(files['completed-quality-report.json'])
    need(api['status'] == 'S29_API_CONTRACT_PROBE_PASS' and api['server_version'] == '0.10.0', 'API outcome/version')
    need(len(api['cases']) == 28 and len({c['case'] for c in api['cases']}) == 28 and all(c['outcome'] == 'pass' for c in api['cases']), 'case coverage')
    required = {'ungranted_user_cannot_open_project','completed_quality_bytes_survive_new_process','terminal_metadata_sse_closes','same_key_changed_form_409','domain_json_error_422','domain_html_error_422','viewer_refusals_preserve_verified_project_backup_bytes'}
    need(required <= {c['case'] for c in api['cases']}, 'required cases')
    need(len(api['requests']) == 33 and Counter(r['status'] for r in api['requests']) == {200:13,202:3,303:6,403:4,404:3,409:1,422:3}, 'HTTP outcome coverage')
    need(type(backup['schema_version']) is int and backup['schema_version'] == 1, 'backup schema')
    need(digest(canonical(backup['payload'])) == backup['digest_sha256'], 'backup canonical digest')
    job,model = api['replay_job_id'],api['replay_model_id']
    payload = backup['payload']
    meta = payload['discovery_jobs'][job]
    need(meta['snapshot']['state'] == 'completed' and meta['model_id'] == model and model in payload['models'] and meta['log_id'] in payload['logs'], 'expected completed backup resources')
    qpaths = {r['path'] for r in api['requests'] if re.fullmatch(r'/quality/jobs/job-[0-9]+/report',r['path'])}
    need(len(qpaths) == 1, 'one completed quality job')
    qjob = next(iter(qpaths)).split('/')[3]
    qmeta = payload['quality_jobs'][qjob]
    need(qmeta['snapshot']['state'] == 'completed' and qmeta['model_id'] == model and qmeta['log_id'] == quality['evaluation']['log_id'], 'quality metadata binding')
    def normalized(value):
        return value.replace('/projects/'+backup['source_project_id'],'/projects/{project}').replace('/logs/'+meta['log_id'],'/logs/{log}').replace('/discovery/jobs/'+job,'/discovery/jobs/{job}').replace('/quality/jobs/'+qjob,'/quality/jobs/{quality_job}')
    expected = read(Path(__file__).with_name('api-contract-expected.json').read_bytes())
    need([normalized(c['case']) for c in api['cases']] == expected['cases'], 'exact case contract')
    need([[r['method'],normalized(r['path']),r['status']] for r in api['requests']] == expected['requests'], 'exact method path status contract')
    backup_sha = digest(files['fixture-backup.json'])
    rows = [r for r in api['requests'] if r['path'] == '/backup']
    need(len(rows) == 3 and all(r['status'] == 200 and r['sha256'] == backup_sha for r in rows), 'three verified backup bytes')
    need(api['project_backup_before_sha256'] == api['project_backup_after_sha256'] == backup_sha, 'backup before/after binding')
    report_sha = digest(files['completed-quality-report.json'])
    need(report_sha == api['completed_report_sha256'] == native['seed_report_sha256'] == native['probe_report_sha256'].lower(), 'persisted report byte binding')
    need(quality['schema_version'] == 1 and quality['evaluation']['model_id'] == model, 'quality export identity')
    need(native['status'] == 'S29_API_CONTRACT_NATIVE_CLOSED' and native['source_pins'] == 97, 'native closure')
    labels = {'worker','app-live','api-probe','postgres-g1','pg-stop-g1','cluster','ready-01','ready-02'}
    need(set(native['records']) == labels, 'native capture coverage')
    for label,record in native['records'].items():
        allowed = (0,1,2) if label.startswith('ready-') else (137,) if label == 'app-live' else (0,)
        need(type(record['native_exit']) is int and record['native_exit'] in allowed and record['source_status'] == 'captured', 'native exit/source')
        need(all(record[key] is True for key in ('stdout_complete','stderr_complete','retained_native_handle','resumed')), 'complete native capture')
        need(all(record[key] is False for key in ('stdout_fault','stderr_fault','stdout_truncated','stderr_truncated','drain_timeout')), 'native capture faults')
    need(native['seed_app_pid'] != native['probe_app_pid'] and native['seed_app_creation_filetime'] < native['probe_app_creation_filetime'], 'external process restart evidence')
    need(native['records']['app-live']['pid'] == native['probe_app_pid'] and native['records']['app-live']['native_creation_filetime'] == native['probe_app_creation_filetime'], 'retained process identity')
    need(native['seed_image_sha256'] == native['probe_image_sha256'], 'same preserved executable bytes')
    need(review['status'] == 'PASS_SPRINT29_SCOPED_API_CONTRACT_LOCAL_ACCEPTANCE' and review['blockers'] == [] and review['source_commit'] == native['source_commit'], 'independent local acceptance')
    need(api['deployment_tls_ha_claimed'] is False and api['api_support_sla_claimed'] is False, 'limited scope')
    return dict(status='S29_SAVED_API_EVIDENCE_PASS',files=5,cases=28,requests=33,backup_copies_identical=3,fresh_execution_claimed=False)


if __name__ == '__main__':
    try:
        need(len(sys.argv) == 2,'one evidence directory required')
        print(json.dumps(verify(sys.argv[1]),sort_keys=True))
    except Exception as error:
        print(json.dumps(dict(status='FAIL',reason=str(error))),file=sys.stderr)
        raise SystemExit(1)
