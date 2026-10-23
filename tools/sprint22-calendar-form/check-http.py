"""Independent finite calendar-form HTTP checks; Root alone executes.

Actual HTTP and authenticated storage comparison, never a browser claim.
Manual Berlin spring/fall expectations are fixed at 7200000/14400000 ms.
Credentials and response headers are never written to the public proof.
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
    p.add_argument("--candidate", choices=("C02", "C03"), required=True)
    p.add_argument("--baseline", type=Path)
    a = p.parse_args()
    u = urllib.parse.urlsplit(a.url)
    assert u.scheme == "http" and u.hostname == "127.0.0.1" and u.port == 3141
    assert not u.username and not u.password and not u.path and not u.query and not u.fragment
    assert a.output.is_dir() and not any(a.output.iterdir()), "fresh owned output required"
    assert a.credentials.parent.is_dir() and a.credentials.parent != a.output
    assert not a.credentials.is_symlink() and not a.output.is_symlink()
    deadline = time.monotonic() + 180
    events, results = [], []
    session = None
    sequence = 0

    def save(name, body):
        assert len(body) <= 2 * 1024 * 1024
        with (a.output / name).open("xb") as f:
            f.write(body)
        return {"file": name, "bytes": len(body), "sha256": sha(body)}

    def request(method, path, body=None, content_type=None, accept=None):
        nonlocal sequence
        assert re.fullmatch(r"/[A-Za-z0-9_./-]*", path)
        assert sequence < 48 and time.monotonic() < deadline
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
            if accept is not None:
                headers["Accept"] = accept
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
            evidence = None if path in ("/setup", "/login", "/users") else save(f"http-{sequence:02d}.bin", data)
            event = {"method": method, "path": path, "status": response.status,
                           "wall_seconds": time.monotonic()-start, "response": evidence, "accept": accept}
            event["selected_response_headers"] = {
                k: v for k, v in ((k.lower(), v) for k, v in response.getheaders())
                if k in ("content-type", "cache-control", "vary")}
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

    def form(path, values, accept=None):
        return request("POST", path, urllib.parse.urlencode(values).encode(), "application/x-www-form-urlencoded", accept)

    def get(path):
        status, _, body = request("GET", path)
        assert status == 200, (path, status)
        return body

    def export(log):
        return json.loads(get("/logs/"+log+"/export"))

    def cookie(headers):
        cookies = SimpleCookie()
        cookies.load(headers.get("set-cookie", ""))
        token = cookies["pi_session"].value
        assert re.fullmatch(r"[A-Za-z0-9_-]{16,256}", token)
        return token

    def project_named(name):
        assert form("/projects", {"name": name})[0] == 303
        projects = json.loads(get("/project-list/json"))["projects"]
        selected = [v["id"] for v in projects if v["name"] == name]
        assert len(selected) == 1
        assert re.fullmatch(r"project-[a-f0-9]{32}", selected[0])
        return selected[0]

    def comparable(value):
        rows = value["business_durations"]
        assert len(rows) == 2
        expected = {"case-0": 7200000, "case-1": 14400000}
        for row in rows:
            assert row["status"] == "computed"
            assert type(row["business_millis"]) is int
            assert row["business_millis"] == expected.pop(row["case_id"])
        assert not expected
        return {"calendar": value["parameters"]["calendar"],
                "business_durations": rows}

    def denied(status, headers, body, expected_status, code):
        assert status == expected_status
        assert "application/json" in headers.get("content-type", "")
        assert json.loads(body)["code"] == code
        assert b"calendar_security_probe" not in body
        assert "Настройки не сохранены.".encode() not in body
        assert "Результаты по последнему сохранённому календарю".encode() not in body

    try:
        if a.credentials.exists():
            assert a.credentials.stat().st_size <= 4096
            credentials = json.loads(a.credentials.read_text(encoding="utf-8"))
            assert credentials["base_url"] == a.url
            session = credentials["session"]
        else:
            assert a.candidate == "C02"
            credentials = {"username": "form-"+secrets.token_hex(5),
                           "password": secrets.token_urlsafe(24)}
            status, headers, _ = form("/setup", credentials)
            assert status == 303
            session = cookie(headers)
            credentials.update(session=session, base_url=a.url)
            with a.credentials.open("x", encoding="utf-8") as f:
                json.dump(credentials, f)
        assert re.fullmatch(r"[A-Za-z0-9_-]{16,256}", session)
        project = project_named("calendar-form-"+a.candidate)
        assert form("/projects/"+project+"/open", {})[0] == 303
        csv = ("case,activity,timestamp\n"
               "spring,begin,2026-03-28T23:00:00Z\n"
               "spring,end,2026-03-29T22:00:00Z\n"
               "fall,begin,2026-10-24T22:00:00Z\n"
               "fall,end,2026-10-25T23:00:00Z\n").encode()
        save("calendar-form.csv", csv)
        boundary = "calendarform"+secrets.token_hex(12)
        upload = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="calendar-form.csv"\r\nContent-Type: text/csv\r\n\r\n'.encode()
                  +csv+f'\r\n--{boundary}--\r\n'.encode())
        status, _, preview = request("POST", "/csv/preview", upload, "multipart/form-data; boundary="+boundary)
        assert status == 200
        tokens = set(re.findall(rb'name="token" value="([a-f0-9]{32})"', preview))
        assert len(tokens) == 1
        status, headers, _ = form("/csv/import", {
            "token": next(iter(tokens)).decode(), "case_column": "case",
            "activity_column": "activity", "timestamp_column": "timestamp",
            "lifecycle_column": "", "order": "source"})
        location = headers.get("location", "")
        assert status == 303 and re.fullmatch(r"/logs/[A-Za-z0-9_-]+", location)
        log = location.split("/")[-1]
        path = "/logs/"+log+"/calendar"
        policy = {"timezone": "Europe/Berlin", "offset_minutes": 0,
                  "weekdays": "7", "start_minute": 60, "end_minute": 240, "holidays": ""}
        assert form(path, policy)[0] == 303
        before = export(log)
        comparison = comparable(before)
        audit_before = json.loads(get("/audit/export"))
        invalid = {**policy, "timezone": "Unknown/calendar_security_probe"}
        status, headers, body = form(path, invalid)
        assert status == 422 and "application/json" in headers.get("content-type", "")
        assert json.loads(body)["code"] == "calendar_timezone"
        default_json = body
        status, headers, body = form(path, invalid, "text/html")
        assert status == 422
        if a.candidate == "C02":
            assert "application/json" in headers.get("content-type", "") and body == default_json
        else:
            assert "text/html" in headers.get("content-type", "")
            assert headers.get("cache-control") == "no-store"
            assert "accept" in headers.get("vary", "").lower()
            html = body.decode()
            assert 'role="alert"' in html and "Настройки не сохранены." in html
            assert "Результаты по последнему сохранённому календарю" in html
            assert invalid["timezone"] in html and "2 ч" in html and "4 ч" in html
        after = export(log)
        audit_after = json.loads(get("/audit/export"))
        assert before == after, "rejected forms changed full saved export/version"
        assert audit_before == audit_after, "rejected forms changed actual project audit"
        assert form(path, policy, "text/html")[0] == 303
        assert comparable(export(log)) == comparison
        security = []
        if a.candidate == "C03":
            viewer = {"username": "form-viewer-"+secrets.token_hex(5),
                      "password": secrets.token_urlsafe(24)}
            assert form("/users", viewer)[0] == 303
            owner_session = session
            member_path = "/projects/"+project+"/members"
            assert form(member_path, {"username": viewer["username"], "role": "viewer"})[0] == 303
            status, headers, _ = form("/login", viewer)
            assert status == 303
            viewer_session = cookie(headers)
            session = viewer_session
            assert form("/projects/"+project+"/open", {})[0] == 303
            denied(*form(path, invalid, "text/html"), 403, "access_denied")
            security.append("viewer_denied_without_draft")
            session = owner_session
            assert form(member_path, {"username": viewer["username"], "role": "editor"})[0] == 303
            session = viewer_session
            status, headers, body = form(path, invalid, "text/html")
            assert status == 422 and "text/html" in headers.get("content-type", "")
            assert "Настройки не сохранены.".encode() in body
            session = owner_session
            assert form(member_path, {"username": viewer["username"], "role": "viewer"})[0] == 303
            session = viewer_session
            denied(*form(path, invalid, "text/html"), 403, "access_denied")
            security.append("write_role_revoked_fresh_request_denied")
            session = owner_session
            foreign = project_named("calendar-form-foreign-C03")
            assert form("/projects/"+foreign+"/open", {})[0] == 303
            denied(*form(path, invalid, "text/html"), 404, "not_found")
            security.append("cross_project_not_found_without_draft")
            assert form("/projects/"+project+"/open", {})[0] == 303
        if a.baseline:
            assert a.candidate == "C03" and a.baseline.stat().st_size <= 1024*1024
            baseline = json.loads(a.baseline.read_text(encoding="utf-8"))
            assert baseline["candidate"] == "C02" and baseline["comparison"] == comparison
            assert baseline["default_json_sha256"] == sha(default_json)
        assert (a.candidate == "C03") == bool(a.baseline)
        proof = {"status": "FINITE_ACTUAL_CALENDAR_FORM_HTTP_PASS", "candidate": a.candidate,
                 "baseline_compared": bool(a.baseline), "project_id": project, "log_id": log,
                 "comparison": comparison, "saved_export_unchanged_after_invalid": before == after,
                 "default_json_sha256": sha(default_json),
                 "audit_unchanged_after_invalid": audit_before == audit_after,
                 "security": security, "requests": events, "browser_observed": False,
                 "limits": ["HTTP only; browser acceptance is separate.",
                            "Auth grants are intentional mutations outside the invalid-form audit comparison.",
                            "No engine/timezone/duration/schema/filter changes or broad R5 claim."]}
        save("proof.json", json.dumps(proof, ensure_ascii=False, indent=2).encode())
    except Exception as e:
        save("failure.json", json.dumps({"status": "FAILED_PARTIAL_ONLY", "exception_type": type(e).__name__,
                                        "requests": events}, ensure_ascii=False, indent=2).encode())
        raise


if __name__ == "__main__":
    main()

