"""Private, bounded API observer for real stock-process interruption/retry."""
import argparse
import hashlib
import http.cookiejar
import json
import re
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["seed", "submit", "check-crashed", "check-completed", "recover", "verify"] , required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--label", default="crash-completed")
    args = parser.parse_args()
    out = args.output.resolve(strict=True)
    first_input = b"case,activity,timestamp,lifecycle\r\none,A,,\r\n"
    second_input = b"case,activity,timestamp,lifecycle\r\none,B,,\r\n"
    base = "http://127.0.0.1:3135"
    credentials_path = out / "crash-private-credentials.json"

    if args.mode in ("check-crashed", "check-completed"):
        raw = args.snapshot.read_bytes()
        assert len(raw) <= 8 * 1024 * 1024
        snapshot = json.loads(raw)
        metas = [meta for project in snapshot["projects"] for meta in project["document"].get("conversions", {}).values()]
        artifacts = [row for row in snapshot["records"] if row["kind"] == "conversion"]
        if args.mode == "check-completed":
            assert re.fullmatch(r"[a-z][a-z0-9-]{0,63}", args.label)
            retry = json.loads((out / "crash-retry-proof.json").read_text(encoding="utf-8"))
            found = [meta for meta in metas if meta["snapshot"]["id"] == retry["job_id"]]
            assert len(found) == 1 and found[0]["snapshot"]["state"] == "completed"
            assert found[0]["retry_of"] == retry["retry_of"]
            row = [row["document"] for row in artifacts if row["resource_id"] == retry["artifact_id"]]
            assert len(row) == 1 and row[0]["input"].encode() == second_input
            for part in ("payload", "report"):
                assert sha(row[0][part].encode()) == retry[part + "_sha256"] == found[0][part + "_sha256"]
            save(out / (args.label + "-proof.json"), {"state": "completed", "job_id": retry["job_id"], "pair_committed_in_database": True, "snapshot_sha256": sha(raw)})
            return
        pending = [meta for meta in metas if meta["filename"] == "crash-second.csv"]
        assert len(pending) == 1
        pending = pending[0]
        assert pending["snapshot"]["state"] == "running", "precommit crash did not retain Running"
        assert pending["snapshot"]["result_id"] is None and pending["payload_sha256"] is None and pending["report_sha256"] is None
        artifact = [row["document"] for row in artifacts if row["resource_id"] == pending["artifact_id"]]
        assert len(artifact) == 1 and artifact[0]["input"].encode() == second_input
        assert artifact[0]["payload"] is None and artifact[0]["report"] is None
        seed = json.loads((out / "crash-seed-proof.json").read_text(encoding="utf-8"))
        first = [row["document"] for row in artifacts if row["resource_id"] == seed["artifact_id"]]
        assert len(first) == 1
        assert sha(first[0]["payload"].encode()) == seed["payload_sha256"]
        assert sha(first[0]["report"].encode()) == seed["report_sha256"]
        save(out / "crash-precommit-proof.json", {"job_id": pending["snapshot"]["id"], "artifact_id": pending["artifact_id"], "durable_state": "running", "retained_input_sha256": sha(second_input), "unpublished_pair": True, "previous_pair_unchanged": True, "snapshot_sha256": sha(raw)})
        return

    class LocalRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            target = urllib.parse.urlsplit(newurl)
            if target.scheme != "http" or target.hostname != "127.0.0.1" or target.port != 3135:
                raise ValueError("non-loopback redirect")
            if req.full_url.endswith("/conversions") or req.full_url.endswith("/retry"):
                return None
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), LocalRedirect(), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(path, data=None, content_type=None, redirect=False):
        headers = {"Origin": base}
        if content_type:
            headers["Content-Type"] = content_type
        req = urllib.request.Request(base + path, data=data, headers=headers)
        try:
            with opener.open(req, timeout=5) as response:
                body = response.read(8 * 1024 * 1024 + 1)
                assert response.status == 200 and len(body) <= 8 * 1024 * 1024
                return body
        except urllib.error.HTTPError as error:
            if redirect and error.code == 303 and error.headers.get("Location") == "/conversions":
                error.close()
                return b"ACCEPTED_303"
            raise

    def form(path, values):
        return request(path, urllib.parse.urlencode(values).encode(), "application/x-www-form-urlencoded")

    def upload(filename, data):
        boundary = "s21crash" + secrets.token_hex(12)
        body = b""
        for name, value in (("from", "csv"), ("to", "xes")):
            body += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\nContent-Type: text/csv\r\n\r\n'.encode() + data + f"\r\n--{boundary}--\r\n".encode()
        assert request("/conversions", body, "multipart/form-data; boundary=" + boundary, redirect=True) == b"ACCEPTED_303"

    def ids():
        html = request("/conversions").decode()
        return sorted(set(re.findall(r"/conversions/jobs/(job-[0-9]+)(?:[/\"'])", html)))

    def metadata(job):
        return json.loads(request("/conversions/jobs/" + job))

    def completed(job):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            meta = metadata(job)
            state = meta["snapshot"]["state"]
            if state == "completed":
                return meta
            assert state in ("queued", "running"), f"unexpected conversion state: {state}"
            time.sleep(0.05)
        raise TimeoutError("conversion did not complete")

    def pair(meta, label, expected=None):
        job = meta["snapshot"]["id"]
        hashes = {}
        for part in ("payload", "report"):
            data = request("/conversions/jobs/" + job + "/" + part)
            hashes[part + "_sha256"] = sha(data)
            assert hashes[part + "_sha256"] == meta[part + "_sha256"]
            if expected:
                assert hashes[part + "_sha256"] == expected[part + "_sha256"]
            with (out / (label + "-" + part)).open("xb") as stream:
                stream.write(data)
        return hashes

    assert json.loads(request("/health")) == {"status": "ready", "version": "0.8.0"}
    if args.mode == "seed":
        credentials = {"username": "s21-crash-owner", "password": secrets.token_urlsafe(24)}
        save(credentials_path, credentials)
        form("/setup", credentials)
        assert not ids()
        upload("crash-first.csv", first_input)
        jobs = ids()
        assert len(jobs) == 1
        meta = completed(jobs[0])
        hashes = pair(meta, "original")
        save(out / "crash-seed-proof.json", {"job_id": jobs[0], "artifact_id": meta["artifact_id"], "actual_http_seed": True, **hashes})
    else:
        credentials = json.loads(credentials_path.read_text(encoding="utf-8"))
        form("/login", credentials)
        if args.mode == "submit":
            upload("crash-second.csv", second_input)
            save(out / "crash-submit-proof.json", {"accepted_status": 303, "source_sha256": sha(second_input), "filename": "crash-second.csv"})
            return
        seed = json.loads((out / "crash-seed-proof.json").read_text(encoding="utf-8"))
        pair(completed(seed["job_id"]), args.mode + "-original", seed)
        interrupted = json.loads((out / "crash-precommit-proof.json").read_text(encoding="utf-8"))
        meta = metadata(interrupted["job_id"])
        assert meta["snapshot"]["state"] == "failed" and meta["snapshot"]["stage"] == "interrupted"
        assert meta["snapshot"]["error"]["code"] == "interrupted"
        assert meta["snapshot"]["result_id"] is None and meta["payload_sha256"] is None and meta["report_sha256"] is None
        if args.mode == "recover":
            previous = set(ids())
            assert request("/conversions/jobs/" + interrupted["job_id"] + "/retry", b"", "application/x-www-form-urlencoded", redirect=True) == b"ACCEPTED_303"
            added = set(ids()) - previous
            assert len(added) == 1
            meta = completed(added.pop())
            assert meta["retry_of"] == interrupted["job_id"] and meta["snapshot"]["id"] != interrupted["job_id"]
            hashes = pair(meta, "retried")
            save(out / "crash-retry-proof.json", {"job_id": meta["snapshot"]["id"], "artifact_id": meta["artifact_id"], "retry_of": meta["retry_of"], "retained_input_sha256": meta["source_sha256"], "state": "completed", **hashes})
        else:
            retry = json.loads((out / "crash-retry-proof.json").read_text(encoding="utf-8"))
            meta = completed(retry["job_id"])
            assert meta["retry_of"] == retry["retry_of"]
            hashes = pair(meta, "after-second-restart", retry)
            save(out / "crash-restart-proof.json", {"job_id": retry["job_id"], "state": "completed", "original_pair_unchanged": True, "retry_pair_unchanged": True, **hashes})


if __name__ == "__main__":
    main()
