"""Finite live calendar checks. Root alone executes; public proof contains no auth.

No browser claim: these are actual HTTP form submissions without redirect following.
Fixed UTC cases and expected milliseconds come from the pre-existing manual S08
Berlin gap/fold oracle, not from asking either server to compute an expectation.
"""
import argparse
import hashlib
import http.client
import json
import re
import secrets
import socket
import threading
import time
import urllib.parse
from http.cookies import SimpleCookie
from pathlib import Path

ZONE_TEXT = "Название часового пояса неизвестно или несовместимо со смещением. Укажите существующее название со смещением 0 либо только смещение UTC."
BOUNDARY_TEXT = "Расчёт остановлен из-за перехода местного времени. Измените рабочие часы или часовой пояс."
CASES = (
    ("spring", "2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z", 7200000),
    ("fall", "2026-10-24T22:00:00Z", "2026-10-25T23:00:00Z", 14400000),
)


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--credentials", type=Path, required=True)
    p.add_argument("--candidate", choices=("C01", "C02"), required=True)
    p.add_argument("--baseline", type=Path)
    a = p.parse_args()
    u = urllib.parse.urlsplit(a.url)
    assert u.scheme == "http" and u.hostname == "127.0.0.1" and u.port in (3139, 3140)
    assert not u.username and not u.password and not u.path and not u.query and not u.fragment
    assert a.output.is_dir() and not any(a.output.iterdir()), "fresh owned output required"
    assert a.credentials.parent.is_dir() and a.credentials.parent != a.output
    assert not a.credentials.is_symlink() and not a.output.is_symlink()
    deadline = time.monotonic() + 150
    events, results = [], []
    session = None
    sequence = 0

    def save(name, body):
        assert len(body) <= 2 * 1024 * 1024
        with (a.output / name).open("xb") as f:
            f.write(body)
        return {"file": name, "bytes": len(body), "sha256": sha(body)}

    def request(method, path, body=None, content_type=None):
        nonlocal sequence
        assert re.fullmatch(r"/[A-Za-z0-9_./-]*", path)
        assert sequence < 65 and time.monotonic() < deadline
        sequence += 1
        start = time.monotonic()
        end = min(deadline, start + 10)
        conn = http.client.HTTPConnection(u.hostname, u.port, timeout=max(.01, end-start))
        response, active = None, None
        expired = threading.Event()

        def remaining():
            left = end-time.monotonic()
            if left <= 0 or expired.is_set():
                raise TimeoutError("absolute ten-second HTTP bound")
            return left

        def interrupt():
            expired.set()
            s = active if active is not None else conn.sock
            if s is not None:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                s.close()

        timer = threading.Timer(remaining(), interrupt)
        timer.daemon = True
        timer.start()
        try:
            headers = {"Origin": a.url, "Connection": "close"}
            if session:
                headers["Cookie"] = "pi_session=" + session
            if content_type:
                headers["Content-Type"] = content_type
            conn.connect()
            conn.sock.settimeout(remaining())
            conn.request(method, path, body, headers)
            active = conn.sock
            active.settimeout(remaining())
            response = conn.getresponse()
            chunks, total = [], 0
            while not response.isclosed():
                if active.fileno() != -1:
                    active.settimeout(remaining())
                chunk = response.read1(min(65536, 2*1024*1024+1-total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                assert total <= 2*1024*1024, "HTTP byte cap"
            assert response.length in (None, 0), "incomplete HTTP response"
            remaining()
            data = b"".join(chunks)
            # Setup/login response bodies and all response headers stay private.
            evidence = None if path in ("/setup", "/login") else save(f"http-{sequence:02d}.bin", data)
            event = {"method": method, "path": path, "status": response.status,
                           "wall_seconds": time.monotonic()-start, "response": evidence}
            if method == "POST" and re.fullmatch(r"/logs/[A-Za-z0-9_-]+/calendar", path):
                event["calendar_form"] = dict(urllib.parse.parse_qsl(body.decode("ascii"), keep_blank_values=True))
            events.append(event)
            return response.status, {k.lower(): v for k, v in response.getheaders()}, data
        finally:
            timer.cancel()
            timer.join(1)
            if response is not None:
                response.close()
            conn.close()

    def form(path, values):
        return request("POST", path, urllib.parse.urlencode(values).encode(), "application/x-www-form-urlencoded")

    def get(path):
        status, _, body = request("GET", path)
        assert status == 200, (path, status)
        return body

    def export(log):
        return json.loads(get("/logs/"+log+"/export"))

    def business(value):
        return {"calendar": value["parameters"]["calendar"], "business_durations": value["business_durations"]}

    try:
        if a.credentials.exists():
            assert a.credentials.stat().st_size <= 4096
            credentials = json.loads(a.credentials.read_text(encoding="utf-8"))
            assert credentials["base_url"] == a.url
            session = credentials["session"]
        else:
            credentials = {"username": "calendar-"+secrets.token_hex(5), "password": secrets.token_urlsafe(24)}
            status, headers, _ = form("/setup", credentials)
            assert status == 303
            cookies = SimpleCookie()
            cookies.load(headers.get("set-cookie", ""))
            session = cookies["pi_session"].value
            credentials.update(session=session, base_url=a.url)
            with a.credentials.open("x", encoding="utf-8") as f:
                json.dump(credentials, f)
        assert re.fullmatch(r"[A-Za-z0-9_-]{16,256}", session)
        before = {v["id"] for v in json.loads(get("/project-list/json"))["projects"]}
        assert form("/projects", {"name": "calendar-oracle-"+a.candidate})[0] == 303
        added = [v for v in json.loads(get("/project-list/json"))["projects"] if v["id"] not in before]
        assert len(added) == 1
        project = added[0]["id"]
        assert re.fullmatch(r"project-[a-f0-9]{32}", project)
        assert form("/projects/"+project+"/open", {})[0] == 303
        for name, begin, finish, expected_ms in CASES:
            csv = f"case,activity,timestamp\n{name},begin,{begin}\n{name},end,{finish}\n".encode()
            save(name+".csv", csv)
            boundary = "calendar"+secrets.token_hex(12)
            upload = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}.csv"\r\nContent-Type: text/csv\r\n\r\n'.encode()
                      +csv+f'\r\n--{boundary}--\r\n'.encode())
            status, _, html = request("POST", "/csv/preview", upload, "multipart/form-data; boundary="+boundary)
            assert status == 200
            tokens = re.findall(rb'name="token" value="([a-f0-9]{32})"', html)
            assert len(set(tokens)) == 1, "one CSV preview token"
            status, headers, _ = form("/csv/import", {"token": tokens[0].decode(), "case_column": "case", "activity_column": "activity", "timestamp_column": "timestamp", "lifecycle_column": "", "order": "source"})
            location = headers.get("location", "")
            assert status == 303 and re.fullmatch(r"/logs/[A-Za-z0-9_-]+", location)
            log = location.split("/")[-1]
            path = "/logs/"+log+"/calendar"
            policy = {"timezone": "Europe/Berlin", "offset_minutes": 0, "weekdays": "7", "start_minute": 150, "end_minute": 240, "holidays": ""}
            status, headers, _ = form(path, policy)
            assert status == 303 and headers.get("location") == "/logs/"+log+"/tools"
            bad = business(export(log))
            assert len(bad["business_durations"]) == 1
            row = bad["business_durations"][0]
            assert row["case_id"] == "case-0" and row["status"] == "unverified" and row["reason"] == "calendar_boundary"
            html = get("/logs/"+log+"/tools").decode()
            if a.candidate == "C02":
                assert BOUNDARY_TEXT in html
            corrected = {**policy, "start_minute": 60}
            assert form(path, corrected)[0] == 303
            good = business(export(log))
            row = good["business_durations"][0]
            assert row["status"] == "computed" and type(row["business_millis"]) is int and row["business_millis"] == expected_ms
            # Real rejected POSTs cannot create an invalid persisted timezone row.
            for label, invalid in (("unknown_zone", {**corrected, "timezone": "Unknown/Nowhere"}), ("offset_conflict", {**corrected, "offset_minutes": 60})):
                status, _, _ = form(path, invalid)
                assert status == 422, label
                assert business(export(log)) == good, "rejected policy changed durable calendar/business fields"
            assert business(export(log)) == good
            get("/logs/"+log+"/tools")
            results.append({"case": name, "log_id": log, "boundary": bad, "corrected": good, "expected_milliseconds": expected_ms, "both_rejected_updates_preserved_state": True})
        comparable = [{k: v for k, v in row.items() if k != "log_id"} for row in results]
        if a.baseline:
            assert a.baseline.stat().st_size <= 1024*1024
            baseline = json.loads(a.baseline.read_text(encoding="utf-8"))
            assert baseline["candidate"] == "C01" and baseline["comparison"] == comparable
        proof = {"status": "FINITE_ACTUAL_HTTP_CALENDAR_ORACLES_PASS", "candidate": a.candidate,
                 "project_id": project, "results": results, "comparison": comparable, "requests": events,
                 "baseline_compared": bool(a.baseline), "browser_observed": False,
                 "timezone_renderer_branch_observed": False,
                 "limits": ["Unknown/incompatible timezone tested as actual HTTP422, not a fabricated saved UI row.", "Timezone renderer branch and escaping need separate real-engine/renderer regression.", "No browser, SSE, timezone arithmetic change, broad R5 closure or enterprise claim."]}
        save("proof.json", json.dumps(proof, ensure_ascii=False, indent=2).encode())
    except Exception as e:
        save("failure.json", json.dumps({"status": "FAILED_PARTIAL_ONLY", "exception_type": type(e).__name__, "requests": events, "completed_cases": len(results)}, ensure_ascii=False, indent=2).encode())
        raise


if __name__ == "__main__":
    main()
