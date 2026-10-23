"""Finite live compatibility observations; Root executes, QA audits independently."""
import argparse
import os
import hashlib
import http.client
import json
import re
import secrets
import socket
import threading
import time
import urllib.parse
import zlib
from http.cookies import SimpleCookie
from pathlib import Path

MIB = 1024 * 1024
PROFILE = 'gzip-hex-report-v1'
FIXED_SHA = 'CBBD54489E7058054EBB4FD4091759024EA660129E736EF1F7C640C55F55BD8D'
SEED = b'<log><trace><string key="concept:name" value="compat"/><event><string key="concept:name" value="A"/><date key="time:timestamp" value="2026-01-01T00:00:00.000000001Z"/></event><event><string key="concept:name" value="B"/><date key="time:timestamp" value="2026-01-01T00:00:01.000000001Z"/></event></trace></log>'

def sha(data):
    return hashlib.sha256(data).hexdigest().upper()

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result

def parse(data):
    return json.loads(data, object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))

def logical_report(raw, compact):
    value = parse(raw)
    if not compact:
        assert value['schema_version'] == 1
        return value
    assert set(value) == {'schema_version', 'report_profile', 'inner_schema_version', 'codec_sha256', 'decoded_bytes', 'decoded_sha256', 'data_hex'}
    assert value['schema_version'] == 2 and value['inner_schema_version'] == 1
    assert value['report_profile'] == PROFILE
    assert type(value['decoded_bytes']) is int and 0 <= value['decoded_bytes'] <= 64*MIB
    assert re.fullmatch('[a-f0-9]{64}', value['decoded_sha256'])
    assert re.fullmatch('[a-f0-9]{64}', value['codec_sha256'])
    text = value['data_hex']
    assert isinstance(text, str) and len(text) <= 4*MIB and len(text) % 2 == 0
    assert re.fullmatch('[a-f0-9]*', text)
    compressed = bytes.fromhex(text)
    assert compressed[:10] == bytes.fromhex('1f8b08000000000000ff')
    decoder = zlib.decompressobj(31)
    decoded = decoder.decompress(compressed, 64*MIB+1)
    assert len(decoded) <= 64*MIB and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
    assert len(decoded) == value['decoded_bytes'] and sha(decoded).lower() == value['decoded_sha256']
    inner = parse(decoded)
    assert inner['schema_version'] == 1
    return inner

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config',type=Path,required=True)
    ap.add_argument('--config-sha-file',type=Path,required=True)
    args=ap.parse_args()
    def bounded(path,cap):
        assert not path.is_symlink()
        with path.open('rb') as stream:
            raw=stream.read(cap+1)
        assert len(raw)<=cap
        return raw
    rawconfig=bounded(args.config,262144)
    assert sha(rawconfig)==bounded(args.config_sha_file,64).decode('ascii')
    config=parse(rawconfig)
    class Options: pass
    a=Options()
    a.url='http://127.0.0.1:3146'
    a.output=Path(config['output'])/'http-restored'
    a.credentials=Path(config['credentials'])
    a.mode='compact'
    assert a.output.is_dir() and not a.output.is_symlink() and not any(a.output.iterdir())
    credentials_raw=bounded(a.credentials,4096)
    assert sha(credentials_raw)==config['credentials_sha']
    credentials=parse(credentials_raw)
    expected_raw=bounded(Path(config['expected_proof']),2*MIB)
    assert sha(expected_raw)==config['expected_proof_sha']
    expected=parse(expected_raw)
    assert expected['status']=='ACTUAL_COMPACT_COMPAT_HTTP_PASS' and expected['mode']=='original'
    assert {x['id'] for x in expected['jobs']}=={'job-1','job-3','job-5'}
    deadline = time.monotonic()+180
    events, jobs = [], []
    session = None
    total_written = 0

    def save(name, body):
        nonlocal total_written
        assert re.fullmatch('[a-zA-Z0-9_.-]{1,96}', name)
        total_written += len(body)
        assert len(body) <= 20*MIB and total_written <= (24*MIB if a.mode == 'compact' else MIB)
        with (a.output/name).open('xb') as f:
            f.write(body)
            f.flush()
            os.fsync(f.fileno())
        return {'file': name, 'bytes': len(body), 'sha256': sha(body)}

    def request(method, path, body=None, content_type=None, persist=True, cap=2*MIB):
        assert re.fullmatch('/[A-Za-z0-9_./-]*', path)
        assert len(events) < 96 and time.monotonic() < deadline and cap <= 20*MIB
        end = min(deadline, time.monotonic()+10)
        conn = http.client.HTTPConnection('127.0.0.1', 3146, timeout=max(.01,end-time.monotonic()))
        response, active = None, None
        expired = threading.Event()
        def left():
            remaining = end-time.monotonic()
            if remaining <= 0 or expired.is_set():
                raise TimeoutError('absolute HTTP deadline')
            return remaining
        def interrupt():
            expired.set()
            sock = active if active is not None else conn.sock
            if sock is not None:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                sock.close()
        timer = threading.Timer(left(), interrupt)
        timer.daemon = True
        timer.start()
        try:
            headers = {'Origin': a.url, 'Connection': 'close'}
            if session:
                headers['Cookie'] = 'pi_session='+session
            if content_type:
                headers['Content-Type'] = content_type
            conn.connect()
            conn.sock.settimeout(left())
            conn.request(method, path, body, headers)
            active = conn.sock
            active.settimeout(left())
            response = conn.getresponse()
            chunks, size = [], 0
            while not response.isclosed():
                if active.fileno() != -1:
                    active.settimeout(left())
                part = response.read1(min(65536, cap+1-size))
                if not part:
                    break
                chunks.append(part)
                size += len(part)
                assert size <= cap
            assert response.length in (None, 0)
            left()
            raw = b''.join(chunks)
            secret = path in ('/setup', '/login')
            descriptor = save('http-%02d.bin' % (len(events)+1), raw) if persist and not secret else None
            events.append({'method': method, 'path': path, 'status': response.status,
                           'body': descriptor, 'bytes': len(raw), 'sha256': None if secret else sha(raw),
                           'body_not_persisted': descriptor is None})
            with (a.output/'safe-events.jsonl').open('ab') as journal:
                journal.write(json.dumps(events[-1],ensure_ascii=False).encode()+b'\n')
                journal.flush()
                os.fsync(journal.fileno())
            return response.status, {k.lower():v for k,v in response.getheaders()}, raw
        finally:
            timer.cancel()
            timer.join(1)
            if response is not None:
                response.close()
            conn.close()

    def form(path, value):
        return request('POST', path, urllib.parse.urlencode(value).encode(), 'application/x-www-form-urlencoded')

    def get(path, **kw):
        status, _, body = request('GET', path, **kw)
        assert status == 200, (path,status)
        return body

    def listing():
        body = get('/conversions')
        return set(x.decode() for x in re.findall(rb'/conversions/jobs/(job-[0-9]+)(?:[/"\'])', body)), body

    def download(meta, label, compact, expected=None, full=True):
        assert meta['snapshot']['state'] == 'completed'
        job = meta['snapshot']['id']
        assert re.fullmatch('job-[0-9]+', job)
        assert re.fullmatch('conversion-[0-9]+', meta['artifact_id'])
        assert meta.get('report_profile') == (PROFILE if compact else None)
        outputs = {}
        payload = None
        for part, cap in (('payload',20*MIB),('report',4*MIB)):
            raw = get('/conversions/jobs/'+job+'/'+part, persist=False, cap=cap)
            assert sha(raw) == meta[part+'_sha256'].upper()
            observed = {'sha256':sha(raw),'bytes':len(raw),'file':None}
            if full:
                observed = save(label+'-'+part+'.bin',raw)
            if expected:
                assert observed['sha256'] == expected[part]['sha256'] and observed['bytes'] == expected[part]['bytes']
            outputs[part] = observed
            if part == 'payload':
                payload = raw
            else:
                inner = logical_report(raw,compact)
                assert inner['status'] == 'converted' and inner['from'] == meta['from'] and inner['to'] == meta['to']
                assert inner['input_sha256'].upper() == meta['source_sha256'].upper()
                assert inner['input_bytes'] == meta['input_bytes'] and inner['allow_metadata_loss'] is False
                assert inner['target_sha256'].upper() == outputs['payload']['sha256']
                assert inner['target_bytes'] == outputs['payload']['bytes']
                assert inner['evidence']['event_count'] == (2 if label == 'legacy' else 90000)
        item = {'label':label,'id':job,'artifact_id':meta['artifact_id'],'metadata':meta,
                'source_sha256':meta['source_sha256'],**outputs}
        jobs.append(item)
        return payload

    try:
        # Deliberately ignore persisted source URL/session. Authenticate anew into restored DB.
        assert session is None
        status,headers,_=form('/login',{'username':credentials['username'],'password':credentials['password']})
        assert status==303
        cookies=SimpleCookie();cookies.load(headers.get('set-cookie',''))
        session=cookies['pi_session'].value
        assert re.fullmatch('[A-Za-z0-9_-]{16,256}',session)
        projects=parse(get('/project-list/json'))['projects']
        actual_ids={p['id'] for p in projects}
        assert actual_ids==set(config['expected_projects']) and len(projects)==2
        project=expected['project_id']
        assert form('/projects/'+project+'/open',{})[0]==303
        def typed_equal(left,right):
            if type(left) is not type(right):return False
            if isinstance(left,dict):return left.keys()==right.keys() and all(typed_equal(left[k],right[k]) for k in left)
            if isinstance(left,list):return len(left)==len(right) and all(typed_equal(x,y) for x,y in zip(left,right))
            return left==right
        for item in expected['jobs']:
            meta=parse(get('/conversions/jobs/'+item['id']))
            assert typed_equal(meta,item['metadata'])
            download(meta,item['label'],item['label']!='legacy',item,True)
        ids,html=listing()
        assert ids=={'job-1','job-3','job-5'}
        assert b'name="compact_report"' in html and b'name="compact_report" checked' not in html
        result={'status':'ACTUAL_CURRENT_COMPACT_DR_HTTP_PASS','new_owner_login':True,
                'project_id':project,'visible_projects':sorted(actual_ids),'jobs':jobs,'events':events,
                'source_input_coverage':'Pinned restored SQL full-row fingerprints plus exact input SHA/length metadata; no input HTTP endpoint claimed.',
                'limits':['Owner-only; API RBAC coverage carried separately.','No conversion rerun, upload, cluster/PITR or HA claim.']}
        save('proof.json',json.dumps(result,ensure_ascii=False,indent=2).encode())
    except Exception as exc:
        save('failure.json',json.dumps({'status':'FAILED_PARTIAL_ONLY','mode':a.mode,'exception_type':type(exc).__name__,'events':events},ensure_ascii=False,indent=2).encode())
        raise

if __name__=='__main__':
    main()
