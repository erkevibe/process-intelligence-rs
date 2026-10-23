"""Independent finite saved-response calendar audit; no network or server execution.

Usage: python -I -B audit-calendar-proof01.py C01_DIRECTORY C02_DIRECTORY OUTPUT
Reads only small synthetic HTTP evidence. Browser claims require another receipt.
"""
import hashlib
import json
import re
import sys
import time
from pathlib import Path

CASES = (
    ("spring", "2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z", 7200000),
    ("fall", "2026-10-24T22:00:00Z", "2026-10-25T23:00:00Z", 14400000),
)
BOUNDARY = "Расчёт остановлен из-за перехода местного времени. Измените рабочие часы или часовой пояс."


def main():
    assert len(sys.argv) == 4
    deadline = time.monotonic()+20
    total = 0

    def read(root, name):
        nonlocal total
        assert re.fullmatch(r"(?:proof\.json|http-[0-9]{2}\.bin|spring\.csv|fall\.csv)", name)
        path = root/name
        assert not path.is_symlink() and path.is_file()
        assert path.stat().st_size <= 2*1024*1024
        total += path.stat().st_size
        assert total <= 16*1024*1024 and time.monotonic() < deadline
        return path.read_bytes()

    def business(raw):
        v = json.loads(raw)
        return {"calendar": v["parameters"]["calendar"], "business_durations": v["business_durations"]}

    observations = []
    for candidate, dirname in zip(("C01", "C02"), sys.argv[1:3]):
        root = Path(dirname)
        assert root.is_dir() and not root.is_symlink()
        proof_raw = read(root, "proof.json")
        proof = json.loads(proof_raw)
        assert proof["status"] == "FINITE_ACTUAL_HTTP_CALENDAR_ORACLES_PASS" and proof["candidate"] == candidate
        assert proof["browser_observed"] is False and proof["timezone_renderer_branch_observed"] is False
        events = proof["requests"]
        assert 1 <= len(events) <= 65
        names = {"proof.json", "spring.csv", "fall.csv"}
        raw = {}
        for i, e in enumerate(events):
            assert type(e["status"]) is int and 100 <= e["status"] <= 599
            assert type(e["wall_seconds"]) in (int, float) and 0 <= e["wall_seconds"] <= 11
            assert re.fullmatch(r"/[A-Za-z0-9_./-]*", e["path"])
            assert e["method"] in ("GET", "POST")
            if e["response"] is None:
                assert e["path"] in ("/setup", "/login") and e["status"] == 303
                continue
            r = e["response"]
            assert set(r) == {"file", "bytes", "sha256"}
            assert r["file"] == f"http-{i+1:02d}.bin" and r["file"] not in names
            data = read(root, r["file"])
            assert len(data) == r["bytes"] and hashlib.sha256(data).hexdigest().upper() == r["sha256"]
            names.add(r["file"])
            raw[i] = data
            if "calendar_form" in e:
                assert e["method"] == "POST" and re.fullmatch(r"/logs/[A-Za-z0-9_-]+/calendar", e["path"])
                assert set(e["calendar_form"]) == {"timezone", "offset_minutes", "weekdays", "start_minute", "end_minute", "holidays"}
        assert len(list(root.iterdir())) <= 70 and {p.name for p in root.iterdir()} == names
        assert len(proof["results"]) == 2
        comparison = []
        for result, (name, begin, end, milliseconds) in zip(proof["results"], CASES):
            assert result["case"] == name and result["expected_milliseconds"] == milliseconds
            expected_csv = f"case,activity,timestamp\n{name},begin,{begin}\n{name},end,{end}\n".encode()
            assert read(root, name+".csv") == expected_csv
            log = result["log_id"]
            assert re.fullmatch(r"[A-Za-z0-9_-]+", log)
            route = "/logs/"+log
            posts = [(i, e) for i, e in enumerate(events) if e["method"] == "POST" and e["path"] == route+"/calendar"]
            assert len(posts) == 4
            invalid = {"timezone": "Europe/Berlin", "offset_minutes": "0", "weekdays": "7", "start_minute": "150", "end_minute": "240", "holidays": ""}
            valid = {**invalid, "start_minute": "60"}
            expected_forms = (invalid, valid, {**valid, "timezone": "Unknown/Nowhere"}, {**valid, "offset_minutes": "60"})
            expected_statuses = (303, 303, 422, 422)
            exports = []
            for pos, ((index, event), form, status) in enumerate(zip(posts, expected_forms, expected_statuses)):
                assert event["calendar_form"] == form and event["status"] == status
                following_exports = [j for j in range(index+1, posts[pos+1][0] if pos+1 < 4 else len(events)) if events[j]["method"] == "GET" and events[j]["path"] == route+"/export"]
                assert following_exports
                values = [business(raw[j]) for j in following_exports]
                assert all(v == values[0] for v in values)
                exports.append(values[0])
            bad, good = exports[:2]
            assert exports[2:] == [good, good]
            assert bad == result["boundary"] and good == result["corrected"]
            for value, start_minute in ((bad, 150), (good, 60)):
                assert value["calendar"] == {"timezone": "Europe/Berlin", "offset_minutes": 0, "weekdays": [7], "start_minute": start_minute, "end_minute": 240, "holidays": []}
            assert bad["business_durations"] == [{"case_id": "case-0", "status": "unverified", "reason": "calendar_boundary"}]
            rows = good["business_durations"]
            assert len(rows) == 1 and rows[0]["case_id"] == "case-0" and rows[0]["status"] == "computed"
            assert rows[0]["start"] == begin.replace("Z", "+00:00") or rows[0]["start"] == begin
            assert rows[0]["end"] == end.replace("Z", "+00:00") or rows[0]["end"] == end
            assert type(rows[0]["business_millis"]) is int and rows[0]["business_millis"] == milliseconds
            if candidate == "C02":
                pages = [raw[j].decode() for j in range(posts[0][0]+1, posts[1][0]) if events[j]["method"] == "GET" and events[j]["path"] == route+"/tools"]
                assert pages and all(BOUNDARY in page for page in pages)
            comparison.append({"case": name, "boundary": bad, "corrected": good})
        observations.append({"candidate": candidate, "proof_sha256": hashlib.sha256(proof_raw).hexdigest().upper(), "comparison": comparison, "raw_responses_verified": len(raw)})
    assert observations[0]["comparison"] == observations[1]["comparison"]
    out = Path(sys.argv[3])
    assert not out.exists() and out.parent.is_dir()
    result = {"status": "INDEPENDENT_SAVED_HTTP_CALENDAR_MANUAL_ORACLES_AND_C01_C02_PARITY_VERIFIED", "observations": observations, "bytes_read": total, "browser_observed": False, "timezone_renderer_branch_observed": False, "scope": "Two real HTTP boundary cases, exact fixed manual milliseconds, raw response hashes, submitted calendar forms, rejected updates preserve prior state. Browser and engine-to-renderer timezone branch require separate evidence; no broad R5 closure."}
    with out.open("x", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
