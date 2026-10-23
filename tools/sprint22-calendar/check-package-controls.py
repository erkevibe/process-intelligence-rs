"""One positive and four specific package-policy controls; Root-owned execution only.

No subprocess/network/symlink creation. Original public evidence is never mutated.
Usage: SCRIPT EVIDENCE TOOLS FRESH_OWNED_OUTPUT VERIFIER_SHA
"""
import hashlib
import json
import linecache
import runpy
import sys
import time
import traceback
from pathlib import Path

MANIFEST_SHA = "6F838B20B270CA9AE09AABB53DA2858C81A474064775DFF368C8B49FF8F291AA"


def main():
    assert len(sys.argv) == 5
    original, tools, out = map(Path, sys.argv[1:4])
    verifier_sha = sys.argv[4]
    assert len(verifier_sha) == 64 and verifier_sha == verifier_sha.upper()
    assert out.is_dir() and not out.is_symlink() and not any(out.iterdir())
    assert not out.resolve().is_relative_to(original.resolve()) and not out.resolve().is_relative_to(tools.resolve())
    deadline = time.monotonic()+30
    manifest_bytes = (original/"manifest.json").read_bytes()
    assert len(manifest_bytes) <= 128*1024 and hashlib.sha256(manifest_bytes).hexdigest().upper() == MANIFEST_SHA
    manifest = json.loads(manifest_bytes)
    assert len(manifest["files"]) == 101 and manifest["total_bytes"] < 1024*1024
    verifier = tools/"verify-package.py"
    assert verifier.is_file() and not verifier.is_symlink() and verifier.stat().st_size <= 64*1024
    assert hashlib.sha256(verifier.read_bytes()).hexdigest().upper() == verifier_sha
    copied = 0

    def bound():
        assert time.monotonic() < deadline and copied <= 5*1024*1024

    def fixture(label):
        nonlocal copied
        target = out/label
        target.mkdir()
        for entry in manifest["files"]:
            bound()
            name = entry["path"]
            assert not name.startswith("/") and all(part not in ("", ".", "..") for part in name.split("/"))
            src = original/name
            assert src.is_file() and not src.is_symlink() and src.stat().st_size <= 2*1024*1024
            data = src.read_bytes()
            assert len(data) == entry["bytes"] and hashlib.sha256(data).hexdigest().upper() == entry["sha256"]
            dst = target/name
            dst.parent.mkdir(parents=True, exist_ok=True)
            with dst.open("xb") as f:
                f.write(data)
            copied += len(data)
        (target/"manifest.json").write_bytes(manifest_bytes)
        return target

    def replace_json(root, name, value):
        path = root/name
        old_size = path.stat().st_size
        data = json.dumps(value, ensure_ascii=False, indent=2).encode()
        path.write_bytes(data)
        changed_manifest = json.loads((root/"manifest.json").read_bytes())
        entries = [e for e in changed_manifest["files"] if e["path"] == name]
        assert len(entries) == 1
        entries[0].update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest().upper())
        changed_manifest["total_bytes"] += len(data)-old_size
        (root/"manifest.json").write_text(json.dumps(changed_manifest, ensure_ascii=False, indent=2), encoding="utf-8")

    def invoke(root, label, expected_guard=None):
        bound()
        saved = sys.argv
        output = out/(label+".json")
        try:
            sys.argv = [str(verifier), str(root), str(tools), str(output)]
            runpy.run_path(str(verifier), run_name="__main__")
        except AssertionError as error:
            if expected_guard is None:
                raise
            frame = traceback.extract_tb(error.__traceback__)[-1]
            actual_line = linecache.getline(frame.filename, frame.lineno).strip()
            assert Path(frame.filename).resolve() == verifier.resolve() and expected_guard in actual_line, (label, actual_line)
            assert not output.exists(), "rejected package must not produce acceptance"
            return {"control": label, "accepted": False, "exception": "AssertionError", "specific_guard": expected_guard}
        finally:
            sys.argv = saved
        assert expected_guard is None, "bad package was accepted"
        assert json.loads(output.read_bytes())["status"] == "PUBLIC_CALENDAR_PACKAGE_AND_EXECUTED_HTTP_AUDIT_VERIFIED"
        return {"control": label, "accepted": True}

    results = [invoke(original, "positive-original")]
    extra = fixture("extra-file")
    (extra/"unmanifested.txt").write_bytes(b"extra")
    results.append(invoke(extra, "extra-unmanifested", 'assert actual == names | {"manifest.json"}'))
    forged = fixture("forged-public-path")
    process = json.loads((forged/"private-process-summary.json").read_bytes())
    slots = [s for row in process["records"] for s in row["streams"].values() if s["original_bytes_public"]]
    assert len(slots) == 2
    slots[0]["public_path"] = "../outside-native.txt"
    replace_json(forged, "private-process-summary.json", process)
    results.append(invoke(forged, "forged-outside-public-path", "assert public_path in names"))
    private = fixture("private-manifest")
    m = json.loads((private/"manifest.json").read_bytes())
    m["synthetic_private_path_probe"] = "C:/Users/fixture-secret/calendar"
    (private/"manifest.json").write_text(json.dumps(m, ensure_ascii=False), encoding="utf-8")
    results.append(invoke(private, "manifest-private-path", 'assert not re.search(r"(?<![A-Za-z0-9])'))
    directories = fixture("too-many-directories")
    for i in range(201):
        bound()
        (directories/f"empty-{i:03d}").mkdir()
    results.append(invoke(directories, "directory-node-bound", "assert nodes <= 200"))
    bound()
    assert hashlib.sha256((original/"manifest.json").read_bytes()).hexdigest().upper() == MANIFEST_SHA
    assert hashlib.sha256(verifier.read_bytes()).hexdigest().upper() == verifier_sha
    with (out/"controls-proof.json").open("x", encoding="utf-8") as f:
        json.dump({"status": "ACTUAL_ONE_POSITIVE_FOUR_SPECIFIC_PACKAGE_GUARDS_VERIFIED", "verifier_sha256": verifier_sha, "original_manifest_sha256": MANIFEST_SHA, "results": results, "copied_bytes": copied, "original_untouched": True, "network_or_subprocess_or_symlink_created": False}, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
