"""Finite, isolated stock-server API checks. Never starts a process or a server."""
import argparse
import copy
import hashlib
import html
import http.client
import http.cookiejar
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def require(ok, code):
    if not ok:
        raise AssertionError(code)


def sha(raw):
    return hashlib.sha256(raw).hexdigest().upper()


def encoded(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def same(left, right):
    """JSON equality preserves numeric types; True must never equal ordinal 1."""
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(same(left[k], right[k]) for k in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(same(a, b) for a, b in zip(left, right))
    return left == right


def append_durable(path, row):
    raw = encoded(row) + b"\n"
    require(len(raw) <= 65536, "journal_row_bound")
    require((path.stat().st_size if path.exists() else 0) + len(raw) <= 1024 * 1024,
            "journal_file_bound")
    with path.open("ab") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def journal_rows(path):
    if not path.exists():
        return []
    raw = path.read_bytes()
    require(len(raw) <= 1024 * 1024 and (not raw or raw.endswith(b"\n")), "journal_partial_or_oversize")

    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "journal_duplicate_key")
            result[key] = value
        return result

    return [json.loads(line, object_pairs_hook=unique) for line in raw.splitlines()]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Probe:
    def __init__(self, base, out):
        self.base, self.out = base, out
        self.started = time.monotonic()
        self.rows, self.checks, self.total = [], [], 0
        self.check_sequence = 0
        self.clients, self.cookies = {}, {}

    def client(self, who):
        if who not in self.clients:
            self.cookies[who] = http.cookiejar.CookieJar()
            self.clients[who] = urllib.request.build_opener(
                urllib.request.ProxyHandler({}), NoRedirect(),
                urllib.request.HTTPCookieProcessor(self.cookies[who]))
        return self.clients[who]

    def request(self, who, path, form=None, raw=None, headers=None, expected=200, accept_values=None):
        require(len(self.rows) < 512 and time.monotonic() - self.started < 100, "request_budget")
        require(path.startswith("/") and not path.startswith("//"), "relative_request")
        hs = dict(headers or {})
        if form is not None:
            raw = urllib.parse.urlencode(form).encode()
            hs["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(self.base + path, data=raw, headers=hs)
        connection = None
        try:
            opener = self.client(who)
            if accept_values is not None:
                self.cookies[who].add_cookie_header(req)
                connection = http.client.HTTPConnection("127.0.0.1", 3144, timeout=8)
                connection.putrequest(req.get_method(), path)
                for key, value in req.header_items():
                    connection.putheader(key, value)
                for value in accept_values:
                    connection.putheader("Accept", value)
                connection.putheader("Content-Length", str(len(raw or b"")))
                connection.endheaders(raw)
                response = connection.getresponse()
            else:
                response = opener.open(req, timeout=8)
        except urllib.error.HTTPError as error:
            response = error
        try:
            with response:
                body = response.read(2 * 1024 * 1024 + 1)
                require(len(body) <= 2 * 1024 * 1024, "response_bound")
                status = response.status if connection else response.code
                safe_headers = {k.lower(): v for k, v in response.headers.items()
                                if k.lower() in ("content-type", "location", "cache-control", "vary")}
        finally:
            if connection:
                connection.close()
        self.total += len(body)
        require(self.total <= 16 * 1024 * 1024, "aggregate_response_bound")
        name = f"response-{len(self.rows):04}.bin"
        with (self.out / name).open("xb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        self.rows.append({"id": len(self.rows), "actor": who, "path": path,
                          "method": req.get_method(), "status": status,
                          "expected_status": expected,
                          "status_assertion": "passed" if status == expected else "failed",
                          "response_file": name, "response_sha256": sha(body),
                          "response_bytes": len(body), "headers": safe_headers,
                          "request_accept_values": accept_values if accept_values is not None else [hs.get("Accept", "")],
                          "request_sha256": sha(raw or b"")})
        append_durable(self.out / "requests.jsonl", self.rows[-1])
        require(status == expected, f"http_status_{len(self.rows)-1}_{status}_expected_{expected}")
        return body, safe_headers

    def get(self, who, path):
        return json.loads(self.request(who, path)[0])

    def check(self, name, ok):
        self.check_sequence += 1
        require(self.check_sequence <= 2048, "check_journal_bound")
        append_durable(self.out / "checks.jsonl", {"sequence": self.check_sequence,
                       "name": name, "outcome": "passed" if ok else "failed"})
        require(ok, name)
        self.checks.append(name)

    def reconcile(self):
        require(same(journal_rows(self.out / "requests.jsonl"), self.rows), "request_journal_reconciliation")
        expected = [{"sequence": i + 1, "name": name, "outcome": "passed"}
                    for i, name in enumerate(self.checks)]
        require(same(journal_rows(self.out / "checks.jsonl"), expected), "check_journal_reconciliation")
        for row in self.rows:
            raw = (self.out / row["response_file"]).read_bytes()
            require(type(row["response_bytes"]) is int and len(raw) == row["response_bytes"]
                    and sha(raw) == row["response_sha256"], "durable_response_reconciliation")

    def login(self, who, password):
        self.request(who, "/login", {"username": who, "password": password}, expected=303)

    def backup(self):
        return self.get("s24owner", "/backup")["payload"]

    def unchanged(self, name, before):
        self.check(name, same(self.backup(), before))

    def audit(self, label, before, after, action, log_id):
        old, new = before["audit"], after["audit"]
        row = new["entries"][-1]
        # Filter always replaces both Arc payloads, including semantic no-ops.
        # Calendar retains them; an unchanged default policy has no state put.
        resources = [log_id]
        if action == "filter_applied":
            resources += [f"log_{part}/{log_id}" for part in ("analysis", "data", "state")]
        elif not same(before["logs"][log_id]["calendar"], after["logs"][log_id]["calendar"]):
            resources.append(f"log_state/{log_id}")
        self.check(label + "_one_bound_business_audit",
                   type(old["total"]) is int and type(new["total"]) is int
                   and new["total"] == old["total"] + 1
                   and same(new["entries"][:-1], old["entries"])
                   and row["action"] == action and same(row["resources"], sorted(resources))
                   and row["project"] == self.project and row["actor"] == self.owner_actor
                   and row["outcome"] == "committed"
                   and type(row["policy"]["version"]) is int and row["policy"]["version"] == 1
                   and row["policy"]["rule"] == ("source_case_then_activity_projection_v1" if action == "filter_applied" else "half_open_business_calendar_v1"))


FILTER_CASES = [
    ("alpha", [("A", "2026-01-05T09:00:00Z"), ("B", "2026-01-05T10:00:00Z"), ("C", "2026-01-05T11:00:00Z")]),
    ("beta", [("A", "2026-01-06T09:00:00Z"), ("C", "2026-01-06T11:00:00Z")]),
    ("gamma", [("B", "2026-01-07T09:00:00Z")]),
    ("delta", [("A", "2026-01-08T09:00:00Z"), ("B", "2026-01-08T10:00:00Z"), ("B", "2026-01-08T11:00:00Z"), ("C", "2026-01-08T12:00:00Z")]),
]
CALENDAR_CASES = [
    ("ordinary", [("A", "2026-01-05T09:00:00Z"), ("B", "2026-01-05T17:00:00Z")]),
    ("spring", [("A", "2026-03-29T00:00:00Z"), ("B", "2026-03-29T02:00:00Z")]),
    ("fall", [("A", "2026-10-24T23:00:00Z"), ("B", "2026-10-25T03:00:00Z")]),
    ("weekend", [("A", "2026-01-10T09:00:00Z"), ("B", "2026-01-10T17:00:00Z")]),
    ("missing", [("A", None), ("B", None)]),
]


def fixture(name, cases):
    pieces = ['<?xml version="1.0" encoding="UTF-8"?><log xmlns="http://www.xes-standard.org/">',
              f'<string key="concept:name" value="{name}"/>']
    expected = []
    for i, (case_name, events) in enumerate(cases):
        pieces.append(f'<trace><string key="concept:name" value="{case_name}"/>')
        event_rows = []
        for n, (activity, stamp) in enumerate(events):
            pieces.append(f'<event><string key="concept:name" value="{activity}"/><string key="lifecycle:transition" value="complete"/>')
            if stamp:
                pieces.append(f'<date key="time:timestamp" value="{stamp}"/>')
            pieces.append('</event>')
            event_rows.append({"ordinal": n, "activity": activity, "timestamp": stamp, "lifecycle": "complete"})
        pieces.append('</trace>')
        expected.append({"id": f"case-{i}", "name": case_name, "events": event_rows})
    pieces.append('</log>')
    return "".join(pieces).encode(), expected


def upload(probe, name, cases):
    raw, expected = fixture(name, cases)
    boundary = "s24-fixed-fixture-boundary"
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}.xes"\r\nContent-Type: application/xml\r\n\r\n'.encode()
            + raw + f'\r\n--{boundary}--\r\n'.encode())
    before = set(probe.backup()["logs"])
    probe.request("s24owner", "/logs", raw=body,
                  headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    logs = probe.backup()["logs"]
    added = set(logs) - before
    require(len(added) == 1, "one_imported_log")
    log_id = added.pop()
    log = logs[log_id]
    probe.check(name + "_manual_full_cases", same(log["source"]["cases"], expected) and same(log["data"], log["source"]))
    probe.check(name + "_raw_source_hash", log["source_sha256"].upper() == sha(raw))
    with (probe.out / (name + ".xes")).open("xb") as stream:
        stream.write(raw)
    return log_id, log["source"]


def filter_checks(p, log_id, source):
    all_cases = {0: [0, 1, 2], 1: [0, 1], 2: [0], 3: [0, 1, 2, 3]}
    profiles = [
        ("length_closed", {"min_events": "2", "max_events": "3"}, {0: [0, 1, 2], 1: [0, 1]}),
        ("length_min", {"min_events": "2"}, {0: [0, 1, 2], 1: [0, 1], 3: [0, 1, 2, 3]}),
        ("length_max", {"max_events": "2"}, {1: [0, 1], 2: [0]}),
        ("case_activity", {"case_activity": "C"}, {0: [0, 1, 2], 1: [0, 1], 3: [0, 1, 2, 3]}),
        ("retain", {"retain": '["A","C"]'}, {0: [0, 2], 1: [0, 1], 2: [], 3: [0, 3]}),
        ("remove", {"remove": '["B"]'}, {0: [0, 2], 1: [0, 1], 2: [], 3: [0, 3]}),
        ("composition", {"min_events": "2", "max_events": "3", "retain": '["C"]'}, {0: [2], 1: [1]}),
        ("empty_events_retained", {"remove": '["A","B","C"]'}, {0: [], 1: [], 2: [], 3: []}),
        ("no_ui_max_clamp", {"min_events": "100001"}, {}),
        ("unknown_field_ignored", {"extra": "unchanged-contract"}, all_cases),
        ("reset_from_original", {}, all_cases),
    ]
    for label, form, indices in profiles:
        seed = p.backup()["logs"][log_id]
        seeded = bool(seed["data"]["cases"])
        if seeded:
            for who in ("s24owner", "s24editor"):
                p.request(who, f"/logs/{log_id}/selection", {"kind": "case", "id": seed["data"]["cases"][0]["id"]})
        before = p.backup()
        if seeded:
            p.check(label + "_real_view_seed", sum(log_id in views for views in before["user_views"].values()) >= 2)
        p.request("s24owner", f"/logs/{log_id}/filter", form, expected=303)
        after = p.backup()
        old, log = before["logs"][log_id], after["logs"][log_id]
        expected = []
        for i, positions in indices.items():
            case = copy.deepcopy(source["cases"][i])
            case["events"] = [case["events"][n] for n in positions]
            expected.append(case)
        p.check(label + "_full_events_and_ordinals", same(log["data"]["cases"], expected))
        p.check(label + "_source_immutable", same(log["source"], source) and log["source_sha256"] == old["source_sha256"])
        p.check(label + "_analysis_version", type(log["analysis_version"]) is int and type(old["analysis_version"]) is int
                and log["analysis_version"] > old["analysis_version"])
        spec = {"case_activity": form.get("case_activity") or None,
                "min_events": int(form["min_events"]) if form.get("min_events") else None,
                "max_events": int(form["max_events"]) if form.get("max_events") else None,
                "retain_activities": json.loads(form.get("retain") or "[]"),
                "remove_activities": json.loads(form.get("remove") or "[]")}
        p.check(label + "_saved_FilterSpec", same(log["filters"], spec))
        p.check(label + "_calendar_unchanged", same(log["calendar"], old["calendar"]))
        p.check(label + "_other_logs_unchanged", same({k: v for k, v in before["logs"].items() if k != log_id},
                                                        {k: v for k, v in after["logs"].items() if k != log_id}))
        p.check(label + "_all_views_reset", log["selected"] is None and log["selected_case"] is None
                and type(log["view_revision"]) is int and log["view_revision"] == 0
                and not any(log_id in views for views in after["user_views"].values()))
        p.audit(label, before, after, "filter_applied", log_id)
        p.check(label + "_export_saved_policy", same(p.get("s24owner", f"/logs/{log_id}/export")["parameters"]["filters"], spec))
    bad = [("reversed", {"min_events": "3", "max_events": "2"}, "filter_range"),
           ("nonnumeric", {"min_events": "abc"}, "filter_range"),
           ("negative", {"min_events": "-1"}, "filter_range"),
           ("labels_object", {"retain": '{}'}, "filter_labels"),
           ("labels_invalid_json", {"remove": '['}, "filter_labels"),
           ("labels_conflict", {"retain": '["A"]', "remove": '["A"]'}, "filter_conflict")]
    for label, form, code in bad:
        before = p.backup()
        body, hs = p.request("s24owner", f"/logs/{log_id}/filter", form,
                             headers={"Accept": "text/html"}, expected=422)
        p.check(label + "_json_refusal", "application/json" in hs.get("content-type", "") and json.loads(body)["code"] == code)
        p.unchanged(label + "_no_business_mutation", before)


def calendar_checks(p, log_id):
    utc = {"timezone": "", "offset_minutes": "0", "weekdays": "1,2,3,4,5", "start_minute": "540", "end_minute": "1080", "holidays": ""}
    berlin = {**utc, "timezone": "Europe/Berlin", "weekdays": "7", "start_minute": "60", "end_minute": "240"}
    for label, form, values in [
        ("ordinary", utc, [28800000, 0, 0, 0]),
        ("weekend_allowed", {**utc, "weekdays": "6"}, [0, 0, 0, 28800000]),
        ("berlin_elapsed", berlin, [0, 7200000, 14400000, 0]),
        ("holiday", {**berlin, "holidays": "2026-03-29"}, [0, 0, 14400000, 0]),
        ("berlin_saved", berlin, [0, 7200000, 14400000, 0]),
    ]:
        before = p.backup()
        p.request("s24owner", f"/logs/{log_id}/calendar", form, expected=303)
        result = p.get("s24owner", f"/logs/{log_id}/export")["business_durations"]
        p.check(label + "_exact_case_binding", len(result) == 5 and same([r["case_id"] for r in result], [f"case-{i}" for i in range(5)]))
        p.check(label + "_manual_UTC_milliseconds", same([r.get("business_millis") for r in result[:4]], values)
                and all(r["status"] == "computed" for r in result[:4]))
        p.check(label + "_missing_unverified", result[4]["status"] == "unverified" and result[4]["reason"] == "missing_timestamps")
        after = p.backup()
        saved = {"timezone": form["timezone"] or None, "offset_minutes": int(form["offset_minutes"]),
                 "weekdays": [int(v) for v in form["weekdays"].split(',')],
                 "start_minute": int(form["start_minute"]), "end_minute": int(form["end_minute"]),
                 "holidays": form["holidays"].split(',') if form["holidays"] else []}
        if not form["timezone"]:
            del saved["timezone"]  # CalendarSpec omits None in its public serialization.
        p.check(label + "_saved_calendar_policy", same(after["logs"][log_id]["calendar"], saved))
        p.audit(label, before, after, "calendar_changed", log_id)
    invalid = {**berlin, "timezone": '<script>alert("s24")</script>'}
    matrix = [("html", "text/html", True), ("json", "application/json", False),
              ("json_wins", "text/html,application/json", False),
              ("wildcard", "*/*", False), ("zero", "text/html;q=0", False),
              ("malformed", "text/html;q=broken", False), ("positive", "text/html;q=0.8", True)]
    for label, accept, want_html in matrix:
        before = p.backup()
        body, hs = p.request("s24owner", f"/logs/{log_id}/calendar", invalid,
                             headers={"Accept": accept}, expected=422)
        p.check(label + "_content_negotiation", ("text/html" in hs.get("content-type", "")) == want_html)
        if want_html:
            text = body.decode()
            p.check(label + "_escaped_draft", '<script>alert("s24")</script>' not in text
                    and html.escape(invalid["timezone"], quote=True) in text)
            p.check(label + "_last_saved_label", "Настройки не сохранены" in text and "последнему сохранённому" in text)
            p.check(label + "_cache_safety", "no-store" in hs.get("cache-control", "") and hs.get("vary", "").lower() == "accept")
        else:
            p.check(label + "_json_code", json.loads(body)["code"] == "calendar_timezone")
        p.unchanged(label + "_invalid_calendar_no_mutation", before)
    before = p.backup()
    body, hs = p.request("s24owner", f"/logs/{log_id}/calendar", invalid,
                         expected=422, accept_values=["text/html", "application/json"])
    p.check("duplicate_Accept_JSON_wins", "application/json" in hs.get("content-type", "")
            and json.loads(body)["code"] == "calendar_timezone")
    p.unchanged("duplicate_Accept_no_mutation", before)
    for label, changes, code in [
        ("invalid_offset", {"timezone": "", "offset_minutes": "841"}, "calendar_policy"),
        ("named_offset_conflict", {"offset_minutes": "60"}, "calendar_timezone"),
        ("overnight_refused", {"start_minute": "1080", "end_minute": "540"}, "calendar_policy"),
        ("weekday", {"weekdays": "8"}, "calendar_policy"),
        ("holiday_syntax", {"holidays": "not-a-date"}, "calendar"),
        ("oversize_draft", {"holidays": "x" * 17000}, "calendar"),
    ]:
        before = p.backup()
        body, hs = p.request("s24owner", f"/logs/{log_id}/calendar", {**berlin, **changes},
                             headers={"Accept": "application/json"}, expected=422)
        p.check(label + "_exact_JSON_reason", "application/json" in hs.get("content-type", "")
                and json.loads(body)["code"] == code)
        p.unchanged(label + "_JSON_no_mutation", before)
        body, hs = p.request("s24owner", f"/logs/{log_id}/calendar", {**berlin, **changes},
                             headers={"Accept": "text/html"}, expected=422)
        if label == "oversize_draft":
            p.check(label + "_JSON_outside_draft_cap", "application/json" in hs.get("content-type", "") and json.loads(body)["code"] == code)
        else:
            p.check(label + "_semantic_HTML_refusal", "text/html" in hs.get("content-type", "")
                    and "Настройки не сохранены" in body.decode() and "no-store" in hs.get("cache-control", "")
                    and hs.get("vary", "").lower() == "accept")
        p.unchanged(label + "_no_mutation", before)
    before = p.backup()
    body, hs = p.request("s24owner", f"/logs/{log_id}/calendar", {**berlin, "offset_minutes": "not-an-integer"},
                          headers={"Accept": "text/html"}, expected=422)
    p.check("numeric_POST_form_extractor_plain_refusal", hs.get("content-type", "") == "text/plain; charset=utf-8"
            and body == b"Failed to deserialize form body: offset_minutes: invalid digit found in string")
    p.unchanged("numeric_extractor_separate_no_mutation", before)
    p.request("s24owner", f"/logs/{log_id}/calendar", berlin, expected=303)
    p.check("corrected_calendar_durable", p.backup()["logs"][log_id]["calendar"]["timezone"] == "Europe/Berlin")


def rights_checks(p, state):
    log_id, cal_id, pid = state["filter_log"], state["calendar_log"], state["project"]
    for who in ("s24editor", "s24viewer", "s24outside"):
        p.login(who, state["password"])
    p.request("s24editor", f"/projects/{pid}/open", {}, expected=303)
    p.request("s24viewer", f"/projects/{pid}/open", {}, expected=303)
    p.request("s24outside", f'/projects/{state["foreign_project"]}/open', {}, expected=303)
    p.request("s24viewer", f"/logs/{log_id}/export")
    p.request("s24editor", f"/logs/{log_id}/filter", {"max_events": "3"}, expected=303)
    for who, expected in [("s24viewer", 403), ("s24outside", 404)]:
        for target, form in [(f"/logs/{log_id}/filter", {"min_events": "2"}),
                             (f"/logs/{cal_id}/calendar", {"timezone": "Europe/Berlin", "offset_minutes": "0", "weekdays": "7", "start_minute": "60", "end_minute": "240"})]:
            before = p.backup()
            p.request(who, target, form, expected=expected)
            p.unchanged(who + "_denied_no_business_mutation_" + target.rsplit("/", 1)[1], before)
    for path, expected in [(f"/logs/{log_id}/export", 403), (f"/logs/{log_id}/filter", 303)]:
        before = p.backup()
        p.request("anonymous", path, {} if path.endswith("filter") else None, expected=expected)
        p.unchanged("anonymous_unchanged_" + path.rsplit("/", 1)[1], before)
    for path in (f"/logs/{log_id}/export", f"/logs/{cal_id}/tools"):
        body, _ = p.request("s24outside", path, expected=404)
        p.check("foreign_no_payload_" + path.rsplit("/", 1)[1], b"S24-filter" not in body and b"S24-calendar" not in body)
    p.request("s24owner", f"/projects/{pid}/members", {"username": "s24editor", "role": "viewer"}, expected=303)
    before = p.backup()
    p.request("s24editor", f"/logs/{log_id}/filter", {}, expected=403)
    p.request("s24editor", f"/logs/{cal_id}/calendar", {"offset_minutes": "0", "weekdays": "7", "start_minute": "60", "end_minute": "240"}, expected=403)
    p.unchanged("sequential_revocation_current_session_no_mutation", before)
    p.request("s24owner", f"/projects/{pid}/members", {"username": "s24editor", "role": "editor"}, expected=303)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--mode", choices=("pre", "post"), required=True)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--state", required=True, type=Path)
    args = ap.parse_args()
    require(args.base == "http://127.0.0.1:3144", "isolated_base_only")
    require(args.out.is_dir() and not any(args.out.iterdir()), "fresh_private_output")
    p = Probe(args.base, args.out)
    try:
        health = p.get("anonymous", "/health")
        p.check("stock_version_ready", same(health, {"status": "ready", "version": "0.8.2"}))
        if args.mode == "pre":
            require(not args.state.exists(), "fresh_state")
            state = {"password": "S24-" + secrets.token_hex(20)}
            p.request("s24owner", "/setup", {"username": "s24owner", "password": state["password"]}, expected=303)
            projects = p.get("s24owner", "/project-list/json")["projects"]
            require(len(projects) == 1, "fresh_setup_one_project")
            state["project"] = projects[0]["id"]
            p.project = state["project"]
            for who in ("s24editor", "s24viewer", "s24outside"):
                p.request("s24owner", "/users", {"username": who, "password": state["password"]}, expected=303)
            for who, role in [("s24editor", "editor"), ("s24viewer", "viewer")]:
                p.request("s24owner", f'/projects/{state["project"]}/members', {"username": who, "role": role}, expected=303)
            p.request("s24owner", "/projects", {"name": "S24 isolated foreign project"}, expected=303)
            ids = [v["id"] for v in p.get("s24owner", "/project-list/json")["projects"] if v["id"] != state["project"]]
            require(len(ids) == 1, "one_foreign_project")
            state["foreign_project"] = ids[0]
            p.request("s24owner", f'/projects/{ids[0]}/members', {"username": "s24outside", "role": "editor"}, expected=303)
            p.request("s24owner", f'/projects/{state["project"]}/open', {}, expected=303)
            state["filter_log"], source = upload(p, "S24-filter", FILTER_CASES)
            p.owner_actor = p.backup()["audit"]["entries"][-1]["actor"]
            state["calendar_log"], _ = upload(p, "S24-calendar", CALENDAR_CASES)
            p.login("s24editor", state["password"])
            p.request("s24editor", f'/projects/{state["project"]}/open', {}, expected=303)
            filter_checks(p, state["filter_log"], source)
            calendar_checks(p, state["calendar_log"])
            rights_checks(p, state)
            state["backup_before_restart"] = p.backup()
            state["exports_before_restart"] = {key: p.get("s24owner", f'/logs/{state[key]}/export') for key in ("filter_log", "calendar_log")}
            state["audit_before_restart"] = p.get("s24owner", "/audit/export")
            with args.state.open("xb") as stream:
                stream.write(encoded(state))
        else:
            require(args.state.stat().st_size < 2 * 1024 * 1024, "state_bound")
            state = json.loads(args.state.read_bytes())
            p.login("s24owner", state["password"])
            p.request("s24owner", f'/projects/{state["project"]}/open', {}, expected=303)
            p.check("actual_restart_full_project_payload", same(p.backup(), state["backup_before_restart"]))
            for key in ("filter_log", "calendar_log"):
                p.check("actual_restart_full_export_" + key, same(p.get("s24owner", f'/logs/{state[key]}/export'), state["exports_before_restart"][key]))
            audit = p.get("s24owner", "/audit/export")
            p.check("actual_restart_project_audit", same(audit["project_entries"], state["audit_before_restart"]["project_entries"])
                    and same(audit["project_total"], state["audit_before_restart"]["project_total"]))
        p.reconcile()
        proof = {"status": "ACTUAL_CURRENT_API_PASS", "mode": args.mode, "checks": p.checks,
                 "requests": p.rows, "response_bytes": p.total, "fresh_engine_oracle": False,
                 "scope": "Finite stock HTTP form/export/backup policy and sequential rights checks only; no concurrent revocation/all API/enterprise claim"}
        with (args.out / "proof.json").open("xb") as stream:
            stream.write(encoded(proof))
        print(json.dumps({"status": proof["status"], "mode": args.mode, "checks": len(p.checks), "requests": len(p.rows)}))
    except Exception as error:
        failure = {"status": "FAILED_PARTIAL_ONLY", "mode": args.mode, "error_type": type(error).__name__,
                   "code": str(error)[:240], "completed_checks": p.checks, "requests": p.rows}
        with (args.out / "failure.json").open("xb") as stream:
            stream.write(encoded(failure))
        print(json.dumps({"status": "FAILED_PARTIAL_ONLY", "mode": args.mode, "error_type": type(error).__name__}))
        raise


if __name__ == "__main__":
    main()
