"""Finite single-writer/database outage checks against an isolated stock server."""
import argparse
import hashlib
import http.cookiejar
import json
import os
import secrets
import types
from pathlib import Path


HELPER_SHA = "9D870DF8B9FF3D74595596A414B6F6D9BB07A97A33149BF891507C7533571448"


def load_helper(path):
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest().upper() != HELPER_SHA:
        raise AssertionError("helper_source_pin")
    helper = types.ModuleType("s24_operations_api_helper")
    exec(compile(raw, str(path), "exec"), helper.__dict__)
    return helper


def save(path, value, api):
    raw = api.encoded(value)
    api.require(len(raw) < 2 * 1024 * 1024, "private_state_bound")
    with path.open("xb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def load_session(probe, value, api):
    api.require(type(value) is dict and set(value) == {"name", "value", "path", "domain", "expires", "secure"}, "cookie_shape")
    api.require(value["domain"] == "127.0.0.1" and value["path"] == "/", "isolated_cookie_scope")
    probe.client("s24owner")
    probe.cookies["s24owner"].set_cookie(http.cookiejar.Cookie(
        0, value["name"], value["value"], None, False, value["domain"], False, False,
        value["path"], True, value["secure"], value["expires"], False, None, None, {}))


def snapshot(probe, log_id):
    return {"backup": probe.backup(), "export": probe.get("s24owner", f"/logs/{log_id}/export"),
            "audit": probe.get("s24owner", "/audit/export")}


def ready(probe, api):
    probe.check("ready_version", api.same(probe.get("anonymous", "/health"),
                                         {"status": "ready", "version": "0.8.2"}))


def unavailable(probe, path, form, label, api):
    body, headers = probe.request("anonymous" if path == "/health" else "s24owner", path,
                                  form, headers={"Accept": "application/json"}, expected=503)
    error = json.loads(body)
    messages = {"База недоступна. Перезапустите приложение после восстановления базы."} if path == "/health" else {
        "Не удалось открыть проект.",
        "База недоступна; изменение не подтверждено.",
        "База недоступна; изменение не подтверждено. Перезапустите приложение и проверьте сохранённые данные перед повтором.",
    }
    probe.check(label + "_storage_unavailable", "application/json" in headers.get("content-type", "")
                and type(error) is dict and set(error) == {"code", "message"}
                and error["code"] == "storage_unavailable" and error["message"] in messages)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--base", required=True)
    parser.add_argument("--mode", required=True, choices=("seed", "lease-check", "down", "latched", "restored"))
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    api = load_helper(args.helper)
    api.require(__debug__, "optimized_python_refused")
    api.require(args.base == "http://127.0.0.1:3144", "isolated_base_only")
    api.require(args.out.is_dir() and not any(args.out.iterdir()), "fresh_private_output")
    probe = api.Probe(args.base, args.out)
    try:
        if args.mode == "seed":
            api.require(not args.state.exists(), "fresh_private_state")
            ready(probe, api)
            probe.request("s24owner", "/setup", {"username": "s24owner", "password": "S24-" + secrets.token_hex(20)}, expected=303)
            projects = probe.get("s24owner", "/project-list/json")["projects"]
            probe.check("isolated_single_project", len(projects) == 1)
            log_id, _ = api.upload(probe, "S24-operations", api.FILTER_CASES)
            probe.request("s24owner", f"/logs/{log_id}/filter", {"min_events": "2", "max_events": "3"}, expected=303)
            probe.request("s24owner", f"/logs/{log_id}/calendar", {"offset_minutes": "0", "weekdays": "1,2,3,4,5", "start_minute": "540", "end_minute": "1080"}, expected=303)
            cookies = list(probe.cookies["s24owner"])
            probe.check("one_persisted_session_cookie", len(cookies) == 1)
            cookie = cookies[0]
            state = {"log_id": log_id, "project_id": projects[0]["id"],
                     "session": {key: getattr(cookie, key) for key in ("name", "value", "path", "domain", "expires", "secure")},
                     "baseline": snapshot(probe, log_id)}
            # Private file contains the session secret; never include it in public evidence.
            save(args.state, state, api)
        else:
            api.require(args.state.stat().st_size < 2 * 1024 * 1024, "private_state_bound")
            state = json.loads(args.state.read_bytes())
            load_session(probe, state["session"], api)
            log_id = state["log_id"]
            if args.mode in ("down", "latched"):
                unavailable(probe, "/health", None, args.mode + "_health", api)
                unavailable(probe, f"/logs/{log_id}/filter", {"min_events": "99"}, args.mode + "_filter", api)
                unavailable(probe, f"/logs/{log_id}/calendar", {"offset_minutes": "60", "weekdays": "7", "start_minute": "60", "end_minute": "180"}, args.mode + "_calendar", api)
            else:
                ready(probe, api)
                current = snapshot(probe, log_id)
                for part in ("backup", "export"):
                    probe.check(args.mode + "_full_" + part + "_unchanged", api.same(current[part], state["baseline"][part]))
                for part in ("project_entries", "project_total"):
                    probe.check(args.mode + "_" + part + "_unchanged", api.same(current["audit"][part], state["baseline"]["audit"][part]))
            secret = state["session"]["value"].encode()
            probe.check("session_secret_absent_in_responses", all(secret not in (args.out / row["response_file"]).read_bytes() for row in probe.rows))
        probe.reconcile()
        proof = {"status": "ACTUAL_S24_OPERATIONS_HTTP_PASS", "mode": args.mode,
                 "checks": probe.checks, "requests": probe.rows,
                 "scope": "Finite existing single-writer/outage/restart behavior only; broker must independently bind process identity and PG generation chronology; no HA or recovery-time SLO"}
        save(args.out / "proof.json", proof, api)
        print(json.dumps({"status": proof["status"], "mode": args.mode, "checks": len(probe.checks), "requests": len(probe.rows)}))
    except Exception as error:
        save(args.out / "failure.json", {"status": "FAILED_PARTIAL_ONLY", "mode": args.mode,
             "code": str(error)[:240], "checks": probe.checks, "requests": probe.rows}, api)
        raise


if __name__ == "__main__":
    main()
