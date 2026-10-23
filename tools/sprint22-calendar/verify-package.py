"""Bounded public calendar package verification, including downloaded HTTP audit.

Usage: python -I -B verify-package.py EVIDENCE_DIRECTORY TOOLS_DIRECTORY OUTPUT
Screenshots are hash checked; their visual review is a separate human/agent receipt.
Private native streams cannot be re-read from this public metadata projection.
"""
import collections
import hashlib
import json
import os
import re
import runpy
import stat
import sys
import time
from pathlib import Path

AUDITOR_SHA = "E56A567730924F6A8E7C64749C4F6BD2B769D91EEF04DDCC6AFDD8BBCE70F91E"
C02_SHA = "13A43541509807ADDA043A6AD1D32BF9F9BA44A0BBF42318F1A168632D09F32C"
BOUNDARY = "Расчёт остановлен из-за перехода местного времени. Измените рабочие часы или часовой пояс."


def main():
    assert len(sys.argv) == 4
    root, tools, output = map(Path, sys.argv[1:])
    assert root.is_dir() and tools.is_dir() and not root.is_symlink() and not tools.is_symlink()
    assert output.parent.is_dir() and not output.exists()
    deadline = time.monotonic() + 25

    def no_reparse(path):
        metadata = path.lstat()
        assert not stat.S_ISLNK(metadata.st_mode)
        assert not (getattr(metadata, "st_file_attributes", 0) & 0x400)
        return metadata

    def privacy(data):
        text = data.decode("utf-8")
        assert not re.search(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/]|/(?:Users|home)/", text)
        assert not re.search(r'"(?:password|session)"\s*:\s*"[^"\n]+"', text)
        assert not re.search(r"pi_session=[A-Za-z0-9_-]{16,}|Authorization:\s*(?:Bearer|Basic)", text)

    no_reparse(root)
    no_reparse(tools)
    manifest_path = root / "manifest.json"
    assert stat.S_ISREG(no_reparse(manifest_path).st_mode)
    assert manifest_path.stat().st_size <= 128 * 1024
    manifest_raw = manifest_path.read_bytes()
    privacy(manifest_raw)
    manifest = json.loads(manifest_raw)
    assert manifest["schema_version"] == 1 and manifest["c02_sha256"] == C02_SHA
    entries = manifest["files"]
    assert 1 <= len(entries) <= 150 and manifest["file_count"] == len(entries)
    names, total = set(), 0
    for entry in entries:
        name = entry["path"]
        assert re.fullmatch(r"[A-Za-z0-9_./-]+", name) and not name.startswith("/")
        assert all(part not in ("", ".", "..") for part in name.split("/"))
        assert name not in names and name != "manifest.json"
        path = root
        for part in name.split("/"):
            path = path / part
            no_reparse(path)
        assert path.is_file() and path.stat().st_size <= 2 * 1024 * 1024
        data = path.read_bytes()
        total += len(data)
        assert total <= 4 * 1024 * 1024 and time.monotonic() < deadline
        assert len(data) == entry["bytes"]
        assert hashlib.sha256(data).hexdigest().upper() == entry["sha256"]
        if not name.endswith(".png"):
            privacy(data)
        names.add(name)
    actual = set()
    queue, nodes = [root], 1
    while queue:
        directory = queue.pop(0)
        with os.scandir(directory) as children:
            for child in children:
                nodes += 1
                assert nodes <= 200 and time.monotonic() < deadline
                path = Path(child.path)
                metadata = no_reparse(path)
                if stat.S_ISDIR(metadata.st_mode):
                    queue.append(path)
                else:
                    assert stat.S_ISREG(metadata.st_mode)
                    actual.add(path.relative_to(root).as_posix())
                assert len(actual) <= 151
    assert actual == names | {"manifest.json"} and total == manifest["total_bytes"]

    def read_json(name):
        assert name in names
        return json.loads((root / name).read_bytes())

    for case, duration in (("spring", "2 ч"), ("fall", "4 ч")):
        refused = (root / f"browser/{case}-refusal-reload.ax.txt").read_text(encoding="utf-8")
        corrected = (root / f"browser/{case}-corrected-reload.ax.txt").read_text(encoding="utf-8")
        assert BOUNDARY in refused and "text —" in refused
        assert f"text {duration}" in corrected and "text Рассчитано" in corrected
    for reason in ("unknown-zone", "offset-conflict"):
        network = read_json(f"browser/{reason}-network.json")
        assert network["truncated"] is False and network["has_more"] is False
        assert len(network["responses"]) == 1
        response = network["responses"][0]
        assert response["status"] == 422 and response["type"] == "Document"
        assert response["url"] == "http://127.0.0.1:3140/logs/log-4/calendar"
        retained = (root / f"browser/{reason}-prior-state-retained.ax.txt").read_text(encoding="utf-8")
        for value in ("Value: Europe/Berlin", "Value: UTC+00:00", "Начало работы, Value: 01:00", "Конец работы, Value: 04:00", "text 4 ч"):
            assert value in retained
    for name, count in (("renderer", 3), ("existing-calendar", 5)):
        text = (root / f"tests/{name}.stdout").read_text(encoding="utf-8")
        assert f"running {count} tests" in text
        assert f"test result: ok. {count} passed; 0 failed; 0 ignored;" in text
    process = read_json("private-process-summary.json")
    assert process["native_records"] == 35 and process["full_streams"] == 70
    assert process["all_original_native_outputs_public"] is False
    assert process["public_original_stream_files"] == 2 and process["private_original_streams"] == 68
    assert collections.Counter(row["phase"] for row in process["records"]) == {"build01": 4, "build02": 5, "live01": 9, "live02": 16, "audit02": 1}
    public_streams = 0
    public_paths = set()
    for record in process["records"]:
        assert type(record["native_exit"]) is int and record["native_exit"] in (0, 1, 137)
        assert set(record["streams"]) == {"stdout", "stderr"}
        for stream in record["streams"].values():
            assert stream["complete"] is True and type(stream["bytes"]) is int and stream["bytes"] >= 0
            assert re.fullmatch(r"[0-9A-F]{64}", stream["sha256"])
            if stream["original_bytes_public"]:
                public_streams += 1
                public_path = stream["public_path"]
                assert public_path in names and public_path in {"tests/renderer.stdout", "tests/existing-calendar.stdout"}
                assert public_path not in public_paths
                public_paths.add(public_path)
                data = (root / public_path).read_bytes()
                assert len(data) == stream["bytes"] and hashlib.sha256(data).hexdigest().upper() == stream["sha256"]
    assert public_streams == 2 and public_paths == {"tests/renderer.stdout", "tests/existing-calendar.stdout"}
    auditor = tools / "audit-calendar-proof02.py"
    assert stat.S_ISREG(no_reparse(auditor).st_mode) and auditor.stat().st_size <= 64 * 1024
    assert hashlib.sha256(auditor.read_bytes()).hexdigest().upper() == AUDITOR_SHA
    http_output = output.with_suffix(".http.json")
    assert not http_output.exists()
    saved_argv = sys.argv
    try:
        sys.argv = [str(auditor), str(root / "http-c01"), str(root / "http-c02"), str(http_output)]
        runpy.run_path(str(auditor), run_name="__main__")
    finally:
        sys.argv = saved_argv
    assert time.monotonic() < deadline
    result = {"status": "PUBLIC_CALENDAR_PACKAGE_AND_EXECUTED_HTTP_AUDIT_VERIFIED", "manifest_sha256": hashlib.sha256(manifest_raw).hexdigest().upper(), "files": len(actual), "bytes": total + len(manifest_raw), "executed_auditor_sha256": AUDITOR_SHA, "http_audit_sha256": hashlib.sha256(http_output.read_bytes()).hexdigest().upper(), "limits": ["Native raw streams remain private except two exact test stdout files; metadata hashes are not public raw replay.", "Browser AX/network projections checked; screenshot pixels hash checked, separate QA/Customer visual review required.", "No broad R5, performance or enterprise acceptance."]}
    with output.open("x", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
