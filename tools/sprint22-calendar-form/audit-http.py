"""Finite saved HTTP evidence audit. No subprocess/network/browser claim."""
import hashlib
import json
import re
import sys
import time
from pathlib import Path

NOT_SAVED = "Настройки не сохранены."
SAVED = "Результаты по последнему сохранённому календарю"


def main():
    assert len(sys.argv) == 4
    start = time.monotonic()
    roots = [Path(v).resolve() for v in sys.argv[1:3]]
    output = Path(sys.argv[3])
    assert not output.exists()
    total, files = 0, 0

    def read(root, name):
        nonlocal total, files
        assert re.fullmatch(r"(?:http-[0-9]{2}\.bin|proof\.json|calendar-form\.csv)", name)
        path = root / name
        assert not root.is_symlink() and not path.is_symlink()
        assert path.is_file() and path.stat().st_size <= 2*1024*1024
        raw = path.read_bytes()
        total += len(raw)
        files += 1
        assert total <= 16*1024*1024 and files <= 100
        assert time.monotonic()-start < 20
        return raw

    comparisons, summaries, default_hashes = [], [], []
    for root, candidate in zip(roots, ("C02", "C03")):
        proof = json.loads(read(root, "proof.json"))
        assert proof["status"] == "FINITE_ACTUAL_CALENDAR_FORM_HTTP_PASS"
        assert proof["candidate"] == candidate
        assert proof["baseline_compared"] is (candidate == "C03")
        assert proof["browser_observed"] is False
        log = proof["log_id"]
        assert re.fullmatch(r"[A-Za-z0-9_-]+", log)
        events = proof["requests"]
        assert 1 <= len(events) <= 48
        decoded, seen = [], set()
        for event in events:
            item = event["response"]
            if item is None:
                assert event["path"] in ("/setup", "/login", "/users")
                decoded.append((event, None))
                continue
            assert set(item) == {"file", "bytes", "sha256"}
            assert item["file"] not in seen
            seen.add(item["file"])
            body = read(root, item["file"])
            assert type(item["bytes"]) is int and len(body) == item["bytes"]
            assert hashlib.sha256(body).hexdigest().upper() == item["sha256"]
            headers = event["selected_response_headers"]
            assert set(headers) <= {"content-type", "cache-control", "vary"}
            decoded.append((event, body))
        exports = [json.loads(body) for event, body in decoded
                   if event["method"] == "GET" and event["path"] == "/logs/"+log+"/export"]
        audits = [json.loads(body) for event, body in decoded
                  if event["method"] == "GET" and event["path"] == "/audit/export"]
        assert len(exports) == 3 and exports[0] == exports[1]
        assert len(audits) == 2 and audits[0] == audits[1]
        assert audits[0]["project_id"] == proof["project_id"]
        assert type(audits[0]["project_total"]) is int
        compare = None
        for export in exports:
            rows = export["business_durations"]
            assert len(rows) == 2
            expected = {"case-0": 7200000, "case-1": 14400000}
            for row in rows:
                assert row["status"] == "computed"
                assert type(row["business_millis"]) is int
                assert row["business_millis"] == expected.pop(row["case_id"])
            assert not expected
            current = {"calendar": export["parameters"]["calendar"], "business_durations": rows}
            assert compare is None or compare == current
            compare = current
        assert proof["comparison"] == compare
        comparisons.append(compare)
        rejected = [(event, body) for event, body in decoded
                    if event["method"] == "POST" and event["path"] == "/logs/"+log+"/calendar"
                    and event.get("calendar_form", {}).get("timezone") == "Unknown/calendar_security_probe"]
        default = [(e, b) for e, b in rejected if e["accept"] is None]
        assert len(default) == 1
        event, body = default[0]
        assert event["status"] == 422 and json.loads(body)["code"] == "calendar_timezone"
        assert "application/json" in event["selected_response_headers"]["content-type"]
        default_hash = hashlib.sha256(body).hexdigest().upper()
        assert proof["default_json_sha256"] == default_hash
        default_hashes.append(default_hash)
        html = [(e, b) for e, b in rejected if e["accept"] == "text/html"]
        if candidate == "C02":
            assert len(html) == 1 and html[0][0]["status"] == 422 and html[0][1] == body
            assert "application/json" in html[0][0]["selected_response_headers"]["content-type"]
        else:
            assert len(html) == 5
            assert [e["status"] for e, _ in html] == [422, 403, 422, 403, 404]
            for e, b in html:
                h = e["selected_response_headers"]
                if e["status"] == 422:
                    text = b.decode()
                    assert "text/html" in h["content-type"]
                    assert h["cache-control"] == "no-store" and "accept" in h["vary"].lower()
                    assert 'role="alert"' in text and NOT_SAVED in text and SAVED in text
                    assert "Unknown/calendar_security_probe" in text and "2 ч" in text and "4 ч" in text
                else:
                    assert "application/json" in h["content-type"]
                    assert json.loads(b)["code"] == ("not_found" if e["status"] == 404 else "access_denied")
                    assert NOT_SAVED.encode() not in b and SAVED.encode() not in b
                    assert b"calendar_security_probe" not in b
            assert proof["security"] == ["viewer_denied_without_draft", "write_role_revoked_fresh_request_denied", "cross_project_not_found_without_draft"]
        assert proof["saved_export_unchanged_after_invalid"] is True
        assert proof["audit_unchanged_after_invalid"] is True
        summaries.append({"candidate": candidate, "requests": len(events), "raw_responses": len(seen),
                          "full_saved_export_and_project_audit_unchanged": True,
                          "manual_milliseconds": [7200000, 14400000]})
    assert comparisons[0] == comparisons[1] and default_hashes[0] == default_hashes[1]
    result = {"status": "INDEPENDENT_SAVED_CALENDAR_FORM_HTTP_AUDIT_PASS", "candidates": summaries,
              "raw_files_read": files, "raw_bytes_read": total, "default_json_cross_binary_byte_parity": True,
              "browser_observed": False, "scope": "Finite synthetic HTTP/auth/export/audit evidence only; no browser or broad R5 claim."}
    with output.open("x", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
