"""Finite loopback API observations. No server RAM, throughput or browser claim."""
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
import socket
import time
import urllib.parse
from http.cookies import SimpleCookie
from pathlib import Path

spec = importlib.util.spec_from_file_location("capacity_inputs", Path(__file__).with_name("prepare-inputs.py"))
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def ordered_core(data):
    rows = list(csv.reader(io.StringIO(data.decode("utf-8"), newline=""), strict=True))
    assert rows and rows[0] == ["case", "activity", "timestamp", "lifecycle"]
    traces, seen = [], set()
    for row in rows[1:]:
        assert len(row) == 4 and row[0] and row[1]
        if not traces or traces[-1]["name"] != row[0]:
            assert row[0] not in seen
            seen.add(row[0])
            traces.append({"name": row[0], "events": []})
        traces[-1]["events"].append({"activity": row[1], "timestamp": row[2] or None, "lifecycle": row[3] or None})
    return {"traces": traces}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--case", choices=["setup", "control", "padded", "restart-check", "overlap"], required=True)
    args = parser.parse_args()
    if args.url != "http://127.0.0.1:3137":
        raise ValueError("only the fixed owned loopback URL is allowed")
    start = time.monotonic()
    deadline = start + 90
    workspace = Path(__file__).absolute().parents[2]
    inputs = support.contained(workspace, args.inputs)
    support.private_directory(inputs)
    output = support.fresh_private(workspace, args.output)
    credentials_path = support.contained(workspace, args.credentials, must_exist=args.case != "setup")
    credentials_path.relative_to(workspace / ".local" / "sprint21" / "root")
    support.private_directory(credentials_path.parent)
    events, session = [], None

    def bounds():
        if time.monotonic() >= deadline:
            raise TimeoutError("finite HTTP phase deadline")

    def connection(timeout=30):
        bounds()
        return http.client.HTTPConnection("127.0.0.1", 3137, timeout=min(timeout, max(0.001, deadline - time.monotonic())))

    def read_response(conn, label, cap=25 * support.MIB, stop_at=None):
        began = time.monotonic()
        local_deadline = min(deadline, stop_at if stop_at is not None else deadline)
        retained_socket = conn.sock
        def read_bound():
            remaining = local_deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("HTTP read deadline")
            active_socket = conn.sock if conn.sock is not None else retained_socket
            if active_socket is not None:
                active_socket.settimeout(min(30, remaining))
        read_bound()
        response = conn.getresponse()
        events.append({"label": label + "-headers", "status": response.status, "phase_elapsed_seconds": time.monotonic() - start})
        chunks, total = [], 0
        while True:
            bounds()
            read_bound()
            data = response.read(min(65536, cap + 1 - total))
            if not data:
                break
            chunks.append(data)
            total += len(data)
            if total > cap:
                raise ValueError("HTTP response byte cap")
        body = b"".join(chunks)
        event = {"label": label, "status": response.status, "response_bytes": len(body), "response_sha256": sha(body), "response_wall_seconds": time.monotonic() - began, "phase_elapsed_seconds": time.monotonic() - start}
        events.append(event)
        return response.status, dict(response.getheaders()), body

    def request(method, path, data=None, content_type=None, label="request", timeout=30):
        request_until = min(deadline, time.monotonic() + timeout)
        conn = connection(timeout)
        try:
            headers = {"Origin": args.url}
            if session:
                headers["Cookie"] = "pi_session=" + session
            if content_type:
                headers["Content-Type"] = content_type
            conn.request(method, path, body=data, headers=headers)
            return read_response(conn, label, stop_at=request_until)
        finally:
            conn.close()

    def get_json(path, label, timeout=30):
        status, _, body = request("GET", path, label=label, timeout=timeout)
        assert status == 200
        return json.loads(body)

    def ids():
        status, _, body = request("GET", "/conversions", label="conversion-list")
        assert status == 200
        return set(re.findall(r"/conversions/jobs/(job-[0-9]+)(?:[/\"'])", body.decode("utf-8")))

    def multipart_begin(path, filename, timeout=30, hold_deadline=None):
        request_until = min(deadline, time.monotonic() + timeout, hold_deadline if hold_deadline is not None else deadline)
        boundary = "s21capacity" + secrets.token_hex(12)
        prefix = b""
        for name, value in (("from", "xes"), ("to", "csv")):
            prefix += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        prefix += f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\nContent-Type: application/xml\r\n\r\n'.encode()
        suffix = f"\r\n--{boundary}--\r\n".encode()
        length = len(prefix) + path.stat().st_size + len(suffix)
        assert length <= 20 * support.MIB + 65536
        conn = connection(timeout)
        stats = {"filename": filename, "declared_content_length": length, "input_bytes": path.stat().st_size, "file_bytes_sent": 0, "multipart_suffix_sent": False}
        try:
            conn.putrequest("POST", "/conversions")
            conn.putheader("Origin", args.url)
            conn.putheader("Cookie", "pi_session=" + session)
            conn.putheader("Content-Type", "multipart/form-data; boundary=" + boundary)
            conn.putheader("Content-Length", str(length))
            conn.endheaders()
            conn.send(prefix)
            content_hash = hashlib.sha256()
            with path.open("rb") as stream:
                while block := stream.read(65536):
                    bounds()
                    remaining = request_until - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("multipart streaming deadline")
                    conn.sock.settimeout(min(timeout, remaining))
                    conn.send(block)
                    stats["file_bytes_sent"] += len(block)
                    content_hash.update(block)
            stats["input_sha256"] = content_hash.hexdigest().upper()
            stats["file_finished_phase_seconds"] = time.monotonic() - start
            return conn, suffix, stats
        except Exception as error:
            stats["exception"] = type(error).__name__
            stats["phase_elapsed_seconds"] = time.monotonic() - start
            events.append({"label": "multipart-send-failed", **stats})
            conn.close()
            raise

    def upload(path, filename, label):
        request_until = min(deadline, time.monotonic() + 30)
        conn, suffix, stats = multipart_begin(path, filename)
        began = time.monotonic()
        try:
            conn.send(suffix)
            stats["multipart_suffix_sent"] = True
            response = read_response(conn, label, stop_at=request_until)
            events.append({"label": label + "-stream", **stats, "after_file_send_wall_seconds": time.monotonic() - began})
            return response
        finally:
            conn.close()

    def completed_meta(job):
        until = min(deadline, time.monotonic() + 30)
        states = []
        while time.monotonic() < until:
            meta = get_json("/conversions/jobs/" + job, "job-snapshot", timeout=max(0.001, until - time.monotonic()))
            snapshot = meta["snapshot"]
            states.append({"state": snapshot["state"], "revision": snapshot["job_revision"], "phase_elapsed_seconds": time.monotonic() - start})
            if snapshot["state"] in ("completed", "failed", "cancelled"):
                return meta, states
            assert snapshot["state"] in ("queued", "running")
            time.sleep(0.1)
        raise TimeoutError("30-second terminal-job bound")

    def download(meta, label, prior=None):
        hashes = {}
        job = meta["snapshot"]["id"]
        if meta["snapshot"]["state"] == "completed":
            assert meta.get("payload_sha256") and meta.get("report_sha256"), "completed pair metadata missing"
        for part in ("payload", "report"):
            expected = meta.get(part + "_sha256")
            if expected is None:
                continue
            status, _, data = request("GET", "/conversions/jobs/" + job + "/" + part, label=label + "-" + part)
            assert status == 200 and sha(data) == expected.upper()
            with (output / (label + "-" + part)).open("xb") as stream:
                stream.write(data)
            hashes[part + "_sha256"] = sha(data)
            hashes[part + "_bytes"] = len(data)
            if prior:
                assert sha(data) == prior[part + "_sha256"]
            if part == "payload":
                assert data == manual_csv, "actual CSV differs from the prospectively fixed manual target"
                assert ordered_core(data) == expected_core, "independent ordered core mismatch"
            else:
                report = json.loads(data)
                assert report["input_sha256"].upper() == meta["source_sha256"].upper()
                assert report["allow_metadata_loss"] is False
                if meta["snapshot"]["state"] == "completed":
                    assert report["status"] == "converted"
                    assert report["target_sha256"].upper() == meta["payload_sha256"].upper()
                    assert report["evidence"]["source_core"] == expected_core == report["evidence"]["target_core"]
        return hashes

    def run_case(case, suffix=""):
        path = inputs / ("control.xes" if case == "control" else "padded.xes")
        before = ids()
        status, headers, _ = upload(path, "capacity-" + case + suffix + ".xes", case + suffix + "-upload")
        assert status == 303 and headers.get("location", headers.get("Location")) == "/conversions", "upload was not durably accepted"
        new = ids() - before
        matching = []
        for job in new:
            meta = get_json("/conversions/jobs/" + job, "accepted-job-metadata")
            if meta["source_sha256"].upper() == input_rows[path.name]["sha256"]:
                matching.append(job)
        assert len(matching) == 1, "one newly admitted job must match the fixed retained input hash"
        meta, states = completed_meta(matching[0])
        hashes = download(meta, case + suffix)
        converted = meta["snapshot"]["state"] == "completed"
        receipt = {"case": case, "job_id": matching[0], "artifact_id": meta["artifact_id"], "state": meta["snapshot"]["state"], "stage": meta["snapshot"]["stage"], "source_sha256": meta["source_sha256"].upper(), "input_bytes": meta["input_bytes"], "states": states, "loss_consent": False, "manual_csv_and_independent_core_match": converted, "outcome": "CONVERTED_AND_MANUALLY_VERIFIED" if converted else "ACTUAL_NONCONVERTED_TERMINAL_RESULT", **hashes}
        support.save(output / (case + suffix + "-receipt.json"), receipt)
        return receipt

    try:
        manifest = json.loads((inputs / "manifest.json").read_text(encoding="utf-8"))
        assert manifest["source_pins"] == support.PINS and manifest["padded_bytes"] == 18 * support.MIB
        input_rows = {row["file"]: row for row in manifest["files"]}
        assert set(input_rows) == {"control.xes", "padded.xes", "expected.csv", "expected-core.json"}
        for name, row in input_rows.items():
            path = support.contained(workspace, inputs / name)
            assert path.stat().st_size == row["bytes"] <= 25 * support.MIB
            assert support.digest(path, deadline) == row["sha256"]
        assert input_rows["control.xes"]["sha256"] == support.PINS["flat-unicode.xes"]
        assert input_rows["expected.csv"]["sha256"] == support.PINS["flat-unicode.csv"]
        assert input_rows["expected-core.json"]["sha256"] == support.PINS["flat-unicode.manual-core.json"]
        manual_csv = (inputs / "expected.csv").read_bytes()
        expected_core = json.loads((inputs / "expected-core.json").read_text(encoding="utf-8"))
        assert ordered_core(manual_csv) == expected_core == manifest["expected_core"]
        health = get_json("/health", "health")
        assert health["status"] == "ready"
        if args.case == "setup":
            if credentials_path.exists():
                raise FileExistsError("setup credentials path must be fresh")
            credentials = {"username": "capacity-owner-" + secrets.token_hex(4), "password": secrets.token_urlsafe(24)}
            support.save(output / "private-setup-request.json", credentials)
            data = urllib.parse.urlencode(credentials).encode()
            status, headers, _ = request("POST", "/setup", data, "application/x-www-form-urlencoded", "setup")
            assert status == 303
            cookie = SimpleCookie()
            cookie.load(headers.get("set-cookie", headers.get("Set-Cookie", "")))
            session = cookie["pi_session"].value
            assert re.fullmatch(r"[A-Za-z0-9_-]{16,256}", session)
            support.save(credentials_path, {**credentials, "session": session, "base_url": args.url})
            result = {"case": "setup", "status": "ACTUAL_FRESH_ACCOUNT_AND_SESSION", "health": health}
        else:
            credentials = json.loads(credentials_path.read_text(encoding="utf-8"))
            assert credentials["base_url"] == args.url
            session = credentials["session"]
            assert re.fullmatch(r"[A-Za-z0-9_-]{16,256}", session)
            if args.case in ("control", "padded"):
                receipt = run_case(args.case)
                support.save(credentials_path.with_name(credentials_path.stem + "-" + args.case + "-receipt-pointer.json"), {"receipt_path": str(output / (args.case + "-receipt.json")), "receipt_sha256": support.digest(output / (args.case + "-receipt.json"))})
                result = receipt
            elif args.case == "restart-check":
                checked = []
                for case in ("control", "padded"):
                    pointer = json.loads(credentials_path.with_name(credentials_path.stem + "-" + case + "-receipt-pointer.json").read_text(encoding="utf-8"))
                    prior_path = support.contained(workspace, Path(pointer["receipt_path"]))
                    assert support.digest(prior_path) == pointer["receipt_sha256"]
                    prior = json.loads(prior_path.read_text(encoding="utf-8"))
                    meta, states = completed_meta(prior["job_id"])
                    assert meta["snapshot"]["state"] == prior["state"]
                    hashes = download(meta, "restart-" + case, prior)
                    checked.append({"case": case, "job_id": prior["job_id"], "state": prior["state"], "had_completed_pair": prior["state"] == "completed", "states": states, **hashes})
                result = {"case": "restart-check", "saved_pairs_and_terminal_states_unchanged": True, "all_cases_had_completed_pairs": all(row["had_completed_pair"] for row in checked), "cases": checked}
            else:
                before = ids()
                held = []
                closed = []
                hold_until = None
                try:
                    for number in (1, 2):
                        conn, _, stats = multipart_begin(inputs / "padded.xes", "capacity-incomplete-" + str(number) + ".xes", timeout=5, hold_deadline=hold_until)
                        held.append((conn, stats))
                        if hold_until is None:
                            hold_until = time.monotonic() + 2
                        if time.monotonic() >= hold_until:
                            raise TimeoutError("two-second incomplete-client hold budget")
                    conn, suffix, stats = multipart_begin(inputs / "control.xes", "capacity-third-control.xes", timeout=min(5, max(0.001, hold_until - time.monotonic())), hold_deadline=hold_until)
                    try:
                        conn.send(suffix)
                        stats["multipart_suffix_sent"] = True
                        third_status, _, _ = read_response(conn, "overlap-third-response", cap=65536, stop_at=hold_until)
                        events.append({"label": "overlap-third-stream", **stats, "status": third_status, "classification": "existing heavy gate or actual observed response; not new admission proof"})
                    except (TimeoutError, socket.timeout) as error:
                        third_status = None
                        events.append({"label": "overlap-third-timeout", "exception": type(error).__name__, "classification": "no response proven"})
                    finally:
                        conn.close()
                    remaining = hold_until - time.monotonic()
                    if remaining > 0:
                        time.sleep(remaining)
                finally:
                    for conn, stats in held:
                        conn.close()
                        closed.append({**stats, "client_closed_without_multipart_suffix": True, "closed_phase_seconds": time.monotonic() - start})
                    support.save(output / "overlap-client-closures.json", {"clients": closed, "maximum_clients": 3, "hold_limit_seconds": 2, "byte_volume_only": True})
                after = ids()
                for job in after - before:
                    meta = get_json("/conversions/jobs/" + job, "overlap-after-disconnect-metadata")
                    assert not meta["filename"].startswith("capacity-incomplete-"), "incomplete client unexpectedly produced a durable job"
                followup = run_case("control", "-after-overlap")
                result = {"case": "overlap", "maximum_clients": 3, "incomplete_clients_closed": closed, "third_status": third_status, "incomplete_clients_created_no_durable_jobs_observed": True, "followup": followup, "scope": "finite byte-volume observation; existing 503/429 codes retain actual meaning; not body-poll-zero or RAM hard-cap proof"}
        bounds()
        support.save(output / "result.json", {"status": "OBSERVATION_COMPLETED", "result": result, "phase_wall_seconds": time.monotonic() - start, "input_manifest_sha256": support.digest(inputs / "manifest.json"), "events": events, "server_memory_latency_slo_or_browser_acceptance_not_claimed": True})
    except Exception as error:
        support.save(output / "failure.json", {"status": "FAILED", "exception": type(error).__name__, "message": str(error), "phase_wall_seconds": time.monotonic() - start, "events": events, "no_retry_or_input_retuning_performed": True})
        raise


if __name__ == "__main__":
    main()
