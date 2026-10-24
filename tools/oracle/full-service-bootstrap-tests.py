"""Finite, local ZIP identity/containment regressions; no network or execution."""
import hashlib
import importlib.util
import json
import pathlib
import tempfile
import zipfile

script = pathlib.Path(__file__).with_name("full-service-bootstrap.py")
spec = importlib.util.spec_from_file_location("full_service_bootstrap", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# These finite local ZIP tests exercise extraction rules only. Production guard
# remains unchanged; its sprint deadline and free-space policy belong to the
# supervised native bootstrap, not to reusable pure archive regressions.
module.guard = lambda: None
owned = pathlib.Path(__file__).resolve().parents[2] / ".local" / "sprint16" / "service"
base = pathlib.Path(tempfile.mkdtemp(prefix="bootstrap-tests-", dir=owned)).resolve()
assert base.is_relative_to(owned.resolve())


def run(name, entries, expected=None, cap=1024, refuse=False, exact_raw_git=False):
    archive = base / (name + ".zip")
    with zipfile.ZipFile(archive, "w") as z:
        for path, data, mode in entries:
            info = zipfile.ZipInfo("placeholder")
            # ZipInfo normally normalizes Windows backslashes on construction;
            # retain the literal hostile ZIP name for the consumer regression.
            info.filename = path
            info.orig_filename = path
            info.external_attr = mode << 16
            z.writestr(info, data)
    try:
        result = module.extract(archive, base / name, expected, cap, exact_raw_git=exact_raw_git)
    except RuntimeError as e:
        if not refuse:
            raise
        return {"case": name, "status": "PASS_EXPECTED_REFUSAL", "reason": str(e)}
    if refuse:
        raise AssertionError("accepted invalid ZIP: " + name)
    return {"case": name, "status": "PASS", "result": result}


payload = b"real source\n"
sha = hashlib.sha1(b"blob 12\0" + payload).hexdigest()
expected = {"a.java": {"size": len(payload), "sha": sha}}
rows = [
    run("exact", [("core/a.java", payload, 0o100644)], expected),
    run("wrong-blob", [("core/a.java", payload + b"x", 0o100644)], expected, refuse=True),
    run("unexpected", [("core/b.java", payload, 0o100644)], expected, refuse=True),
    run("missing", [("core/", b"", 0o40755)], expected, refuse=True),
    run("casefold", [("core/a.java", payload, 0o100644), ("core/A.java", payload, 0o100644)], refuse=True),
    run("traversal", [("core/../escape", payload, 0o100644)], refuse=True),
    run("backslash", [("core/a\\escape", payload, 0o100644)], refuse=True),
    run("symlink", [("core/a.java", payload, 0o120777)], refuse=True),
    run("decoded-cap", [("core/a.java", payload, 0o100644)], cap=4, refuse=True),
    run("empty", [], refuse=True),
]
raw = b"a\n" * 89 + b"b" * 2496
archive_raw = raw.replace(b"\n", b"\r\n")
relative = "Apromore-Custom-Plugins/Merge-Logic/gradlew.bat"
raw_expected = {relative: {"size": len(raw), "sha": hashlib.sha1(b"blob 2674\0" + raw).hexdigest()}}
original_download = module.download
calls = []


def exact_raw_fetch(url, target, cap, expected_sha):
    calls.append(url)
    assert cap == 8192 and url.endswith(module.CORE + "/" + relative)
    target.write_bytes(raw)
    return {"bytes": len(raw), "synthetic_unit_fetch": True}


module.download = exact_raw_fetch
try:
    rows.append(run("archive-raw-retrieval", [("core/" + relative, archive_raw, 0o100644)], raw_expected, cap=4096, exact_raw_git=True))
    assert len(calls) == 1
    rows.append(run("unexpected-archive-transform", [("core/" + relative, archive_raw + b"x", 0o100644)], raw_expected, cap=4096, refuse=True, exact_raw_git=True))
    assert len(calls) == 1  # Refusal precedes any raw-source fetch.
finally:
    module.download = original_download
report = {"scope": "Synthetic local ZIP/whole-source-identity regressions only", "cases": rows}
with (base / "result.json").open("x", encoding="utf-8") as f:
    json.dump(report, f, indent=2)
print(json.dumps({"status": "PASS", "count": len(rows), "out": str(base)}))
