"""Bounded loopback HTTP fixture and full-value migration snapshot comparisons.

This is an API acceptance observer; it does not claim browser interaction.
Credentials and complete exports stay in the private output directory.
"""
import argparse
import hashlib
import http.cookiejar
import json
import re
import secrets
import urllib.parse
import urllib.request
from pathlib import Path


def save(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["seed", "verify", "compare-migration", "compare-identical"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--before", type=Path)
    parser.add_argument("--after", type=Path)
    parser.add_argument("--label", default="comparison")
    parser.add_argument("--expected-version")
    args = parser.parse_args()
    out = args.output.resolve(strict=True)
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", args.label):
        raise ValueError("label")
    if args.mode.startswith("compare-"):
        before_bytes = args.before.read_bytes()
        after_bytes = args.after.read_bytes()
        if max(len(before_bytes), len(after_bytes)) > 8 * 1024 * 1024:
            raise ValueError("snapshot capacity")
        before, after = json.loads(before_bytes), json.loads(after_bytes)
        if args.mode == "compare-identical":
            assert before == after, "database values changed"
        else:
            for key in ("projects", "records", "kv", "sequence"):
                assert before[key] == after[key], f"{key} changed during migration"
            assert [row["version"] for row in before["ledger"]] == [1, 2]
            assert [row["version"] for row in after["ledger"]] == [1, 2, 3]
            assert before["ledger"] == after["ledger"][:2], "historical migration ledger changed"
            assert after["ledger"][2]["name"] == "conversion_artifacts_v3"
            assert before["projects"] and before["records"], "historical fixture must be populated"
        save(out / (args.label + "-proof.json"), {
            "mode": args.mode, "equal_required_values": True,
            "before_sha256": digest(before_bytes), "after_sha256": digest(after_bytes),
            "projects": len(after["projects"]), "records": len(after["records"]),
            "browser_acceptance_not_claimed": True,
        })
        return

    base = "http://127.0.0.1:3132"

    class LocalRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            target = urllib.parse.urlsplit(newurl)
            if target.scheme != "http" or target.hostname != "127.0.0.1" or target.port != 3132:
                raise ValueError("non-loopback redirect refused")
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), LocalRedirect(),
    )

    def request(path, form=None):
        if not path.startswith("/") or path.startswith("//"):
            raise ValueError("path")
        data = None if form is None else urllib.parse.urlencode(form).encode()
        req = urllib.request.Request(base + path, data=data, headers={"Origin": base})
        with opener.open(req, timeout=10) as response:
            body = response.read(8 * 1024 * 1024 + 1)
            if response.status != 200 or len(body) > 8 * 1024 * 1024:
                raise ValueError("HTTP status or response capacity")
            return body

    health = json.loads(request("/health"))
    assert health == {"status": "ready", "version": args.expected_version}, "unexpected actual binary version"
    credentials_path = out / "historical-private-credentials.json"
    if args.mode == "seed":
        credentials = {"username": "s21-historical-owner", "password": secrets.token_urlsafe(24)}
        save(credentials_path, credentials)
        request("/setup", credentials)
        html = request("/demo", {}).decode("utf-8")
        ids = sorted(set(re.findall(r"/logs/(log-[0-9]+)(?:[/\"?])", html)))
        assert len(ids) == 1, "expected exactly one historical demo log"
        payload = request("/logs/" + ids[0] + "/export")
        exported = json.loads(payload)
        assert exported["log_id"] == ids[0] and exported["source_sha256"]
        with (out / "historical-export-before.json").open("xb") as stream:
            stream.write(payload)
        save(out / "historical-seed-proof.json", {
            "version": args.expected_version, "log_id": ids[0],
            "export_sha256": digest(payload), "export_bytes": len(payload),
            "source_sha256": exported["source_sha256"], "actual_http_setup_demo_export": True,
            "browser_acceptance_not_claimed": True,
        })
    else:
        credentials = json.loads(credentials_path.read_text(encoding="utf-8"))
        seed = json.loads((out / "historical-seed-proof.json").read_text(encoding="utf-8"))
        request("/login", credentials)
        payload = request("/logs/" + seed["log_id"] + "/export")
        assert digest(payload) == seed["export_sha256"], "historical export bytes changed"
        with (out / "historical-export-after.json").open("xb") as stream:
            stream.write(payload)
        save(out / "historical-new-runtime-proof.json", {
            "version": args.expected_version, "log_id": seed["log_id"],
            "export_sha256": digest(payload), "export_bytes": len(payload),
            "same_export_bytes": True, "actual_http_login_export": True,
            "browser_acceptance_not_claimed": True,
        })


if __name__ == "__main__":
    main()
