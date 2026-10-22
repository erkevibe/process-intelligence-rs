"""Two prospectively fixed event-count observations; never a load or RAM bound."""
import sys
sys.dont_write_bytecode = True
import argparse
import csv
import hashlib
import http.client
import importlib.util
import io
import json
import re
import secrets
import time
import urllib.parse
from datetime import datetime, timezone
from http.cookies import SimpleCookie
from pathlib import Path

WORKSPACE = Path(__file__).absolute().parents[3]
spec = importlib.util.spec_from_file_location("private_capacity_support", WORKSPACE / "tools/sprint21-capacity/prepare-inputs.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
APP_SHA = "4121BD68F1C0C05A61B039FADF20FEC5C2DA4379D8AAAFB170DC3B43861D1525"
COUNTS = {"CMP10K": 10000, "CMP90K": 90000}


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def utc():
    return datetime.now(timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--case", choices=COUNTS, required=True)
    args = parser.parse_args()
    if args.url != "http://127.0.0.1:3139":
        raise ValueError("only fixed owned loopback URL allowed")
    started, started_utc = time.monotonic(), utc()
    deadline = started + 120
    inputs = support.contained(WORKSPACE, args.inputs)
    support.private_directory(inputs)
    output = support.fresh_private(WORKSPACE, args.output)
    credentials = support.contained(WORKSPACE, args.credentials, must_exist=args.case != "CMP10K")
    credentials.relative_to(WORKSPACE / ".local/sprint21/root")
    support.private_directory(credentials.parent)
    session, events, states = None, [], []
    submitted = 0

    def bounds():
        if time.monotonic() >= deadline:
            raise TimeoutError("120-second case observation bound")

    def clock():
        return {"utc": utc(), "case_elapsed_seconds": time.monotonic() - started}

    def request(method, path, data=None, content_type=None, label="request", cap=25 * support.MIB):
        bounds()
        began = time.monotonic()
        event = {"label": label, "method": method, "path": path, "request_start": clock()}
        conn = http.client.HTTPConnection("127.0.0.1", 3139, timeout=min(15, deadline - began))
        response = None
        try:
            headers = {"Origin": args.url, "Connection": "close"}
            if session:
                headers["Cookie"] = "pi_session=" + session
            if content_type:
                headers["Content-Type"] = content_type
            conn.request(method, path, body=data, headers=headers)
            retained_socket = conn.sock
            bounds()
            if retained_socket is not None:
                retained_socket.settimeout(min(15, max(0.001, deadline - time.monotonic())))
            response = conn.getresponse()
            event.update(status=response.status, response_headers_observed=clock())
            chunks, total = [], 0
            # HTTPResponse can detach conn.sock on Connection:close. Do not
            # touch a closed socket after EOF or reuse a closed response.
            while not response.isclosed():
                bounds()
                active = conn.sock if conn.sock is not None else retained_socket
                if active is not None and active.fileno() != -1:
                    active.settimeout(min(15, max(0.001, deadline - time.monotonic())))
                chunk = response.read1(min(65536, cap + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > cap:
                    raise ValueError("response byte cap")
            if response.length not in (None, 0):
                raise EOFError("incomplete HTTP response")
            body = b"".join(chunks)
            event.update(response_bytes=len(body), response_sha256=sha(body), response_complete=clock(), request_wall_seconds=time.monotonic() - began)
            return response.status, dict(response.getheaders()), body
        except Exception as error:
            event.update(exception_type=type(error).__name__, exception_utc=utc())
            raise
        finally:
            events.append(event)
            if response is not None:
                response.close()
            conn.close()

    def get_json(path, label):
        status, _, body = request("GET", path, label=label, cap=1024 * 1024)
        if status != 200:
            raise ValueError(label + " expected200 got" + str(status))
        return json.loads(body)

    def form(path, values, label):
        return request("POST", path, urllib.parse.urlencode(values).encode(), "application/x-www-form-urlencoded", label)

    def save_bytes(name, body):
        bounds()
        with (output / name).open("xb") as stream:
            stream.write(body)
        return {"file": name, "bytes": len(body), "sha256": sha(body)}

    def csv_check(body, oracle, count):
        reader = csv.reader(io.StringIO(body.decode("utf-8"), newline=""), strict=True)
        if next(reader, None) != oracle["expected_csv_header"]:
            raise ValueError("CSV header mismatch")
        rows = 0
        for row in reader:
            bounds()
            if row != oracle["expected_csv_row"]:
                raise ValueError("CSV fixed core values mismatch")
            rows += 1
        if rows != count:
            raise ValueError("CSV independent event count mismatch")
        return {"rows": rows, "trace_count": 1, "fixed_values_match": True, "order_sensitivity_not_claimed": True, "newline_normalization": "csv.reader UTF8 newline-empty; raw serializer not preasserted"}

    try:
        manifest_path = support.contained(WORKSPACE, inputs / "manifest.json")
        if manifest_path.stat().st_size > 65536:
            raise ValueError("manifest byte cap")
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
        if manifest["schema_version"] != 1 or manifest["status"] != "PROSPECTIVE_INPUTS_FROZEN_BEFORE_MEASUREMENT" or manifest["app_sha256"] != APP_SHA:
            raise ValueError("prospective manifest contract")
        rows = {row["id"]: row for row in manifest["cases"]}
        if set(rows) != set(COUNTS) or len(manifest["cases"]) != 2:
            raise ValueError("exact two input cases required")
        row = rows[args.case]
        count = COUNTS[args.case]
        if row["events"] != count or row["trace_count"] != 1:
            raise ValueError("fixed count mismatch")
        for key, expected in (("input_file", args.case + ".xes"), ("oracle_file", args.case + "-oracle.json"), ("manual_csv_file", args.case + ".expected-lf.csv")):
            if row[key] != expected:
                raise ValueError("fixed input filename mismatch")
        input_path = support.contained(WORKSPACE, inputs / row["input_file"])
        if not 0 < input_path.stat().st_size <= 20 * support.MIB:
            raise ValueError("input pre-read byte cap")
        data = input_path.read_bytes()
        if not 0 < len(data) <= 20 * support.MIB or len(data) != row["input_bytes"] or sha(data) != row["input_sha256"]:
            raise ValueError("input identity mismatch")
        oracle_path = support.contained(WORKSPACE, inputs / row["oracle_file"])
        if oracle_path.stat().st_size > 65536:
            raise ValueError("oracle byte cap")
        oracle_bytes = oracle_path.read_bytes()
        if sha(oracle_bytes) != row["oracle_sha256"]:
            raise ValueError("oracle identity mismatch")
        oracle = json.loads(oracle_bytes)
        expected_row = ["complexity-case", "A", "2026-01-01T00:00:00.000000001Z", ""]
        if oracle["case_id"] != args.case or oracle["event_count"] != count or oracle["trace_count"] != 1 or oracle["allowed_loss_count"] != 0 or oracle["expected_csv_row"] != expected_row or oracle["expected_csv_header"] != ["case", "activity", "timestamp", "lifecycle"]:
            raise ValueError("independent oracle contract mismatch")
        manual_path = support.contained(WORKSPACE, inputs / row["manual_csv_file"])
        if manual_path.stat().st_size > 8 * support.MIB:
            raise ValueError("manual CSV byte cap")
        manual = manual_path.read_bytes()
        if sha(manual) != row["manual_csv_sha256"]:
            raise ValueError("manual CSV identity mismatch")
        csv_check(manual, oracle, count)
        save_bytes("input-manifest.json", manifest_bytes)
        save_bytes("manual-oracle.json", oracle_bytes)
        health = get_json("/health", "health")
        if health["status"] != "ready":
            raise ValueError("not ready")
        if args.case == "CMP10K":
            if credentials.exists():
                raise FileExistsError("first case credentials must be fresh")
            account = {"username": "complexity-" + secrets.token_hex(4), "password": secrets.token_urlsafe(24)}
            support.save(output / "private-setup-request.json", account)
            status, headers, _ = form("/setup", account, "setup")
            if status != 303:
                raise ValueError("setup status" + str(status))
            cookie = SimpleCookie()
            cookie.load(headers.get("set-cookie", headers.get("Set-Cookie", "")))
            session = cookie["pi_session"].value
            if not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", session):
                raise ValueError("session shape")
            support.save(credentials, {**account, "session": session, "base_url": args.url})
        else:
            saved = json.loads(credentials.read_text(encoding="utf-8"))
            if saved["base_url"] != args.url or not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", saved["session"]):
                raise ValueError("saved session identity")
            session = saved["session"]
        before_projects = {p["id"] for p in get_json("/project-list/json", "projects-before")["projects"]}
        status, _, _ = form("/projects", {"name": "fixed-event-count-" + args.case}, "create-fresh-project")
        if status != 303:
            raise ValueError("project creation status" + str(status))
        projects = get_json("/project-list/json", "projects-after")["projects"]
        new = [p for p in projects if p["id"] not in before_projects]
        if len(new) != 1 or new[0]["name"] != "fixed-event-count-" + args.case:
            raise ValueError("one fresh project required")
        project = new[0]["id"]
        if not re.fullmatch(r"[A-Za-z0-9_-]+", project):
            raise ValueError("project ID shape")
        status, _, _ = form("/projects/" + project + "/open", {}, "open-fresh-project")
        if status != 303:
            raise ValueError("project switch status" + str(status))
        status, _, listing = request("GET", "/conversions", label="empty-conversion-list")
        if status != 200 or re.search(rb"/conversions/jobs/job-[0-9]+", listing):
            raise ValueError("fresh project conversion list not empty")
        boundary = "s21complexity" + secrets.token_hex(12)
        prefix = b"".join(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode() for name, value in (("from", "xes"), ("to", "csv")))
        prefix += f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{args.case}.xes"\r\nContent-Type: application/xml\r\n\r\n'.encode()
        body = prefix + data + f"\r\n--{boundary}--\r\n".encode()
        if len(body) > 20 * support.MIB + 65536:
            raise ValueError("multipart preflight bytes")
        submitted += 1
        upload_start = clock()
        status, headers, upload_body = request("POST", "/conversions", body, "multipart/form-data; boundary=" + boundary, "only-conversion-upload", cap=1024 * 1024)
        upload_end = clock()
        save_bytes("upload-response.bin", upload_body)
        if status != 303 or headers.get("location", headers.get("Location")) != "/conversions":
            support.save(output / "result.json", {"status": "ACTUAL_UPLOAD_REFUSAL", "case": args.case, "http_status": status, "submitted_conversions": submitted, "events": events, "input_sha256": sha(data), "no_terminal_job_or_target_claim": True})
            return
        status, _, listing = request("GET", "/conversions", label="accepted-conversion-list")
        ids = set(re.findall(rb"/conversions/jobs/(job-[0-9]+)(?:[/\"'])", listing))
        if status != 200 or len(ids) != 1:
            raise ValueError("exactly one accepted job required")
        job = next(iter(ids)).decode("ascii")
        first_poll = clock()
        while True:
            bounds()
            meta = get_json("/conversions/jobs/" + job, "job-snapshot")
            states.append({"observed": clock(), "snapshot": meta["snapshot"]})
            support.save(output / ("job-state-" + str(len(states)).zfill(4) + ".json"), meta)
            if len(states) > 1200:
                raise ValueError("poll observation count cap")
            if meta["snapshot"]["state"] in ("completed", "failed", "cancelled"):
                break
            if meta["snapshot"]["state"] not in ("queued", "running"):
                raise ValueError("unknown observed job state")
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        terminal_poll = clock()
        if meta["source_sha256"].upper() != sha(data) or meta["input_bytes"] != len(data) or meta["from"] != "xes" or meta["to"] != "csv" or meta["allow_loss"] is not False:
            raise ValueError("durable metadata source identity mismatch")
        downloads, payload, report = {}, None, None
        for part, cap in (("payload", 20 * support.MIB), ("report", 4 * support.MIB)):
            status, _, raw = request("GET", "/conversions/jobs/" + job + "/" + part, label="terminal-" + part, cap=cap)
            expected_hash = meta.get(part + "_sha256")
            if expected_hash is None:
                if status != 404:
                    raise ValueError("absent " + part + " must return404")
                downloads[part] = {"available": False, "http_status": status}
            else:
                if status != 200 or sha(raw) != expected_hash.upper():
                    raise ValueError("download identity mismatch")
                downloads[part] = {"available": True, "http_status": status, **save_bytes(part + ".bin", raw)}
                if part == "payload":
                    payload = raw
                else:
                    report = json.loads(raw)
        converted = meta["snapshot"]["state"] == "completed"
        verification = None
        if converted:
            if payload is None or report is None:
                raise ValueError("completed pair absent")
            verification = csv_check(payload, oracle, count)
            if report["status"] != "converted" or report["input_sha256"].upper() != sha(data) or report["input_bytes"] != len(data) or report["target_sha256"].upper() != sha(payload) or report["target_bytes"] != len(payload) or report["allow_metadata_loss"] is not False:
                raise ValueError("report identity mismatch")
            evidence = report["evidence"]
            if evidence["event_count"] != count or evidence["trace_count"] != 1 or evidence["metadata_loss_count"] != 0 or evidence["losses"]:
                raise ValueError("report count/loss mismatch")
            for core in (evidence["source_core"], evidence["target_core"]):
                if len(core["traces"]) != 1 or core["traces"][0]["name"] != "complexity-case" or len(core["traces"][0]["events"]) != count:
                    raise ValueError("report core count mismatch")
                if any(e != {"activity": "A", "timestamp": expected_row[2], "lifecycle": None} for e in core["traces"][0]["events"]):
                    raise ValueError("report fixed core mismatch")
        else:
            if payload is not None or meta["snapshot"]["result_id"] is not None:
                raise ValueError("noncompleted result unexpectedly published")
            error = meta["snapshot"].get("error") or {}
            if error.get("code") == "report_byte_limit" and report is not None:
                raise ValueError("oversized failure report unexpectedly published")
        bounds()
        support.save(output / "result.json", {"status": "OBSERVATION_COMPLETED", "case": args.case, "events_expected": count, "input_bytes": len(data), "input_sha256": sha(data), "input_manifest_sha256": sha(manifest_bytes), "manual_oracle_sha256": sha(oracle_bytes), "app_sha256": APP_SHA, "project_id": project, "job_id": job, "artifact_id": meta["artifact_id"], "submitted_conversions": submitted, "allow_metadata_loss": False, "outcome": meta["snapshot"], "metadata": meta, "downloads": downloads, "manual_core_verification": verification, "request_upload_start": upload_start, "request_upload_response": upload_end, "first_poll": first_poll, "terminal_poll": terminal_poll, "started_utc": started_utc, "finished_utc": utc(), "case_wall_seconds": time.monotonic() - started, "events": events, "states": states, "scope": "One fixed count observation; identical repeated values do not test ordering sensitivity. HTTP/poll wall observations are not CPU/admission/queue internals. Durable source hash/bytes observed in metadata, not independent source-byte retrieval. Server memory is measured by external owned observer. No SLO or RAM cap."})
    except Exception as error:
        support.save(output / "failure.json", {"status": "FAILED", "case": args.case, "exception_type": type(error).__name__, "message": str(error), "finished_utc": utc(), "case_wall_seconds": time.monotonic() - started, "submitted_conversions": submitted, "events": events, "states": states, "retry_or_input_retuning_performed": False})
        raise


if __name__ == "__main__":
    main()
