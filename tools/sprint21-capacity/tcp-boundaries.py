"""Finite actual TCP framing probes; no RAM, throughput, browser or recovery claim."""
import sys
sys.dont_write_bytecode = True
import argparse
import csv
import hashlib
import http.client
import importlib.util
import io
import json
from pathlib import Path
import re
import secrets
import select
import time
import traceback

spec = importlib.util.spec_from_file_location('capacity_inputs', Path(__file__).with_name('prepare-inputs.py'))
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
BASE = 'http://127.0.0.1:3137'
BODY_CAP = 20 * 1024 * 1024 + 65536
RESPONSE_CAP = 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def core(data):
    rows = list(csv.reader(io.StringIO(data.decode('utf-8'), newline=''), strict=True))
    assert rows[0] == ['case', 'activity', 'timestamp', 'lifecycle']
    traces, seen = [], set()
    for row in rows[1:]:
        assert len(row) == 4 and row[0] and row[1]
        if not traces or traces[-1]['name'] != row[0]:
            assert row[0] not in seen
            seen.add(row[0]); traces.append({'name': row[0], 'events': []})
        traces[-1]['events'].append({'activity': row[1], 'timestamp': row[2] or None, 'lifecycle': row[3] or None})
    return {'traces': traces}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--credentials', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert args.url == BASE
    workspace = Path(__file__).absolute().parents[2]
    inputs = support.contained(workspace, args.inputs)
    support.private_directory(inputs)
    credentials = support.contained(workspace, args.credentials)
    credentials.relative_to(workspace / '.local/sprint21/root')
    support.private_directory(credentials.parent)
    assert credentials.stat().st_size <= 65536
    output = support.fresh_private(workspace, args.output)
    started = time.monotonic(); deadline = started + 90
    events = []; posts = gets = 0
    private_values = []

    def diagnostics(error):
        def redact(text):
            for value in private_values:
                text = text.replace(value, '[PRIVATE]')
            return text
        return {'exception': type(error).__name__, 'errno': getattr(error, 'errno', None),
                'winerror': getattr(error, 'winerror', None), 'message': redact(str(error)),
                'traceback': redact(traceback.format_exc())}

    def bound(until=None):
        remaining = min(deadline, until if until is not None else deadline) - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('finite TCP boundary deadline')
        return min(10, remaining)

    def save(label, value):
        support.save(output / (label + '.json'), value)

    def write(label, raw):
        with (output / label).open('xb') as stream:
            stream.write(raw)

    def begin(method, route, label, extra=None, stop_at=None):
        nonlocal posts, gets
        bound()
        if method == 'POST':
            posts += 1; assert posts <= 3
        else:
            assert method == 'GET'; gets += 1; assert gets <= 32
        until = min(deadline, time.monotonic() + 10, stop_at if stop_at is not None else deadline)
        connection = http.client.HTTPConnection('127.0.0.1', 3137, timeout=bound(until))
        entry = {'label': label, 'method': method, 'route': route,
                 'started_seconds': time.monotonic() - started, 'actual_status': None}
        events.append(entry)
        connection.putrequest(method, route)
        connection.putheader('Origin', BASE)
        connection.putheader('Cookie', 'pi_session=' + session)
        connection.putheader('Connection', 'close')
        for key, value in (extra or {}).items(): connection.putheader(key, value)
        connection.endheaders()
        return connection, until, entry

    def response(connection, until, entry):
        retained_socket = connection.sock
        def socket_bound():
            timeout = bound(until)
            sock = connection.sock if connection.sock is not None else retained_socket
            if sock is not None: sock.settimeout(timeout)
        socket_bound()
        result = connection.getresponse()
        try:
            entry['actual_status'] = result.status
            entry['response_headers'] = {key.lower(): value for key, value in result.getheaders()
                                         if key.lower() in ('content-type', 'content-disposition', 'x-content-type-options')}
            pieces = []; total = 0
            # getresponse() may detach the connection on Connection: close. The
            # response fp owns the socket until the final read closes it. Check
            # that lifecycle before attempting any further socket operation.
            while not result.isclosed():
                socket_bound()
                piece = result.read1(min(65536, RESPONSE_CAP + 1 - total))
                bound(until)
                if not piece: break
                pieces.append(piece); total += len(piece)
                assert total <= RESPONSE_CAP, 'response byte cap'
            body = b''.join(pieces)
            if result.length not in (None, 0):
                raise http.client.IncompleteRead(body, result.length)
            entry.update(response_bytes=len(body), response_sha256=sha(body), finished_seconds=time.monotonic() - started)
            write(f'{len(events):03}-{entry["label"]}.body', body)
            save(f'{len(events):03}-{entry["label"]}', entry)
            return result.status, body
        finally:
            result.close()

    def get(route, label, stop_at=None):
        connection, until, entry = begin('GET', route, label, stop_at=stop_at)
        try:
            return response(connection, until, entry)
        finally:
            connection.close()

    def ids(label):
        status, body = get('/conversions', label)
        assert status == 200
        return set(re.findall(r'/conversions/jobs/(job-[0-9]+)(?:[/"\'])', body.decode('utf-8')))

    def multipart(filename):
        boundary = 's21tcp' + secrets.token_hex(12)
        prefix = b''
        for name, value in (('from', 'xes'), ('to', 'csv')):
            prefix += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        prefix += f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\nContent-Type: application/xml\r\n\r\n'.encode()
        return boundary, prefix, f'\r\n--{boundary}--\r\n'.encode()

    def chunked(prefix, suffix, chunks, filename, label):
        boundary = filename  # The caller supplies the matching boundary string.
        connection, until, entry = begin('POST', '/conversions', label, {
            'Content-Type': 'multipart/form-data; boundary=' + boundary,
            'Transfer-Encoding': 'chunked'})
        entry.update(content_length_present=False, transfer_encoding='chunked', file_bytes_sent=0,
                     file_chunks_sent=0, multipart_suffix_sent=False, terminal_chunk_sent=False)
        try:
            try:
                def send_chunk(data):
                    connection.sock.settimeout(bound(until))
                    connection.send(f'{len(data):X}\r\n'.encode() + data + b'\r\n')
                send_chunk(prefix)
                early_response = False
                for piece in chunks:
                    bound(until)
                    assert 0 < len(piece) <= 65536
                    if select.select([connection.sock], [], [], 0)[0]:
                        entry['response_ready_during_upload'] = True
                        early_response = True
                        break
                    send_chunk(piece)
                    entry['file_bytes_sent'] += len(piece); entry['file_chunks_sent'] += 1
                if not early_response:
                    send_chunk(suffix); entry['multipart_suffix_sent'] = True
                    connection.send(b'0\r\n\r\n'); entry['terminal_chunk_sent'] = True
            except (OSError, http.client.HTTPException) as error:
                entry['write_exception'] = type(error).__name__
                entry['write_errno'] = getattr(error, 'errno', None)
                entry['write_diagnostics'] = diagnostics(error)
            # A write close is never counted as HTTP 413. Always attempt to read
            # the actual response on the same connection before closing it.
            try:
                return response(connection, until, entry)
            except (OSError, http.client.HTTPException, TimeoutError) as error:
                entry['read_exception'] = type(error).__name__
                entry['read_diagnostics'] = diagnostics(error)
                save(label + '-response-unconfirmed', entry)
                raise
        finally:
            connection.close()

    try:
        manifest_path = support.contained(workspace, inputs / 'manifest.json')
        assert manifest_path.stat().st_size <= RESPONSE_CAP
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        assert manifest['source_pins'] == support.PINS
        rows = {row['file']: row for row in manifest['files']}
        assert set(rows) == {'control.xes', 'padded.xes', 'expected.csv', 'expected-core.json'}
        for name, row in rows.items():
            path = support.contained(workspace, inputs / name)
            assert path.stat().st_size == row['bytes'] <= 25 * support.MIB
            assert support.digest(path, deadline) == row['sha256']
        assert rows['control.xes']['sha256'] == support.PINS['flat-unicode.xes']
        assert rows['expected.csv']['sha256'] == support.PINS['flat-unicode.csv']
        assert rows['expected-core.json']['sha256'] == support.PINS['flat-unicode.manual-core.json']
        control = (inputs / 'control.xes').read_bytes(); expected = (inputs / 'expected.csv').read_bytes()
        core_bytes = (inputs / 'expected-core.json').read_bytes()
        assert sha(control) == support.PINS['flat-unicode.xes']
        assert sha(expected) == support.PINS['flat-unicode.csv']
        assert sha(core_bytes) == support.PINS['flat-unicode.manual-core.json']
        expected_core = json.loads(core_bytes)
        assert len(control) == 430 and len(expected) == 125 and core(expected) == expected_core == manifest['expected_core']
        credential = json.loads(credentials.read_text(encoding='utf-8'))
        private_values.extend(value for key in ('username', 'password', 'session')
                              if isinstance((value := credential.get(key)), str) and value)
        assert credential['base_url'] == BASE
        session = credential['session']; assert re.fullmatch('[A-Za-z0-9_-]{16,256}', session)

        before = ids('before-probes')
        boundary, _, _ = multipart('tcp-declared-overcap.xes')
        connection, until, entry = begin('POST', '/conversions', 'declared-overcap', {
            'Content-Type': 'multipart/form-data; boundary=' + boundary,
            'Content-Length': str(BODY_CAP + 1)})
        entry.update(declared_content_length=BODY_CAP + 1, file_bytes_sent=0, headers_only=True)
        try:
            status, _ = response(connection, until, entry)
        finally:
            connection.close()
        assert status == 413, 'actual oversized Content-Length response must be 413'
        assert ids('after-declared-overcap') == before

        boundary, prefix, suffix = multipart('tcp-chunked-control.xes')
        status, _ = chunked(prefix, suffix, iter([control]), boundary, 'chunked-control')
        assert status == 303
        after = ids('after-chunked-control'); created = after - before; assert len(created) == 1
        job = created.pop(); job_until = min(deadline, time.monotonic() + 20); states = []
        while True:
            bound(job_until)
            status, body = get('/conversions/jobs/' + job, 'control-snapshot-' + str(len(states)), stop_at=job_until)
            assert status == 200
            meta = json.loads(body); states.append(meta['snapshot']['state'])
            assert meta['source_sha256'].upper() == sha(control) and meta['input_bytes'] == 430
            if meta['snapshot']['state'] in ('completed', 'failed', 'cancelled'): break
            time.sleep(min(1, max(0, job_until - time.monotonic())))
        assert meta['snapshot']['state'] == 'completed'
        status, payload = get('/conversions/jobs/' + job + '/payload', 'control-payload'); assert status == 200
        status, report_bytes = get('/conversions/jobs/' + job + '/report', 'control-report'); assert status == 200
        report = json.loads(report_bytes)
        assert payload == expected and len(payload) == 125 and core(payload) == expected_core
        assert sha(payload) == meta['payload_sha256'].upper() and sha(report_bytes) == meta['report_sha256'].upper()
        assert report['status'] == 'converted' and report['input_sha256'].upper() == sha(control)
        assert report['target_sha256'].upper() == sha(payload) and report['allow_metadata_loss'] is False
        assert report['evidence']['source_core'] == expected_core == report['evidence']['target_core']
        write('control.payload.csv', payload); write('control.report.json', report_bytes); save('control-meta', meta)

        boundary, prefix, suffix = multipart('tcp-chunked-overcap.xes')
        producer_bytes = 20 * support.MIB + 128 * 1024
        def oversized_chunks():
            remaining = producer_bytes
            while remaining:
                bound()
                piece = b' ' * min(65536, remaining)
                remaining -= len(piece)
                yield piece
        status, _ = chunked(prefix, suffix, oversized_chunks(), boundary, 'chunked-overcap')
        assert status == 413, 'actual unknown-length overcap response must be 413'
        assert ids('after-chunked-overcap') == after
        assert posts == 3 and gets <= 32
        save('result', {'status': 'PASSED', 'post_probes': posts, 'observation_gets': gets,
                        'control_job': job, 'control_source_sha256': sha(control), 'control_payload_sha256': sha(payload),
                        'control_states': states, 'response_cap': RESPONSE_CAP, 'request_timeout_seconds': 10,
                        'multipart_body_cap': BODY_CAP, 'unknown_length_producer_file_cap': producer_bytes,
                        'input_manifest_sha256': support.digest(manifest_path, deadline),
                        'total_wall_seconds': time.monotonic() - started, 'events': events,
                        'scope': 'actual TCP framing and semantic control only; no memory/throughput/browser/recovery claim'})
        print(json.dumps({'status': 'PASSED', 'post_probes': posts, 'observation_gets': gets, 'control_job': job}))
    except Exception as error:
        save('failure', {'status': 'FAILED', **diagnostics(error), 'post_probes': posts,
                         'observation_gets': gets, 'events': events, 'wall_seconds': time.monotonic() - started})
        print(json.dumps({'status': 'FAILED', 'exception': type(error).__name__}))
        raise SystemExit(1)

if __name__ == '__main__':
    main()
