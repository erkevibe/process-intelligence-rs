"""Fetch verified private canonical inputs; never edits upstream build/source files.

The output is source/dependency preparation, not service execution or acceptance.
Uses only the Python standard library. Source ZIP payloads must match the entire
pinned Git tree; Gradle distribution must match its official published SHA256.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import stat
import time
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone

CORE = "bbf24dfd43e72d6992392465f875a4367cbe792b"
TREE = "c9f89200ad1170a4aed9711b5174234e7ec2dc18"
TREE_SHA256 = "bce30c8d971da259d4947f7ae9db904765dc1e980f5b9d41ccd86567a45fd96f"
GRADLE_SHA = "bf8b869948901d422e9bb7d1fa61da6a6e19411baa7ad6ee929073df85d6365d"
DEADLINE = datetime(2026, 10, 20, 19, 46, 17, tzinfo=timezone.utc).timestamp()
HOSTS = {"github.com", "codeload.github.com", "services.gradle.org",
         "downloads.gradle.org", "release-assets.githubusercontent.com", "raw.githubusercontent.com"}
RAW_GIT_ARCHIVE_EXCEPTIONS = {
    "Apromore-Custom-Plugins/Merge-Logic/gradlew.bat",
    "Apromore-Custom-Plugins/Merge-Portal-Plugin/gradlew.bat",
}
RAW_BAT_SHA256 = "c46a27c79007746de5922b17abb6230d64ad8b1ba3ad1585ee5c6543c2a9b129"


def guard():
    if time.time() >= DEADLINE:
        raise RuntimeError("sprint runtime deadline")
    if shutil.disk_usage(pathlib.Path(__file__).resolve().parents[2]).free < 8 * 1024**3:
        raise RuntimeError("free disk floor")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()


class Redirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlparse(newurl)
        if target.scheme != "https" or target.hostname not in HOSTS:
            raise RuntimeError("unexpected redirect destination")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url, target, cap, expected=None):
    guard()
    initial = urllib.parse.urlparse(url)
    if initial.scheme != "https" or initial.hostname not in HOSTS:
        raise RuntimeError("unexpected requested URL")
    started = time.monotonic()
    opener = urllib.request.build_opener(Redirect())
    req = urllib.request.Request(url, headers={"User-Agent": "process-intelligence-service-reference"})
    size = 0
    with opener.open(req, timeout=15) as response, target.open("xb") as output:
        if response.status != 200:
            raise RuntimeError("HTTP status")
        final = urllib.parse.urlparse(response.url)
        if final.scheme != "https" or final.hostname not in HOSTS:
            raise RuntimeError("unexpected final URL")
        while True:
            guard()
            if time.monotonic() - started > 180:
                raise RuntimeError("download wall clock limit")
            b = response.read(1024 * 1024)
            if not b:
                break
            size += len(b)
            if size > cap:
                raise RuntimeError("download byte cap")
            output.write(b)
    actual = digest(target)
    if expected and actual != expected:
        raise RuntimeError("download SHA256 mismatch")
    return {"requested_url": url, "final_host": final.hostname,
            "final_path": final.path, "bytes": size, "sha256": actual,
            "anonymous": True, "complete_eof": True}


def extract(archive, destination, expected=None, cap=512 * 1024 * 1024, exact_raw_git=False):
    destination.mkdir()
    seen = set()
    folded = set()
    total = 0
    replacements = []
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist()
        if not entries or len(entries) > 12000:
            raise RuntimeError("ZIP entry count")
        prefix = entries[0].filename.split("/")[0]
        for e in entries:
            guard()
            bits = pathlib.PurePosixPath(e.filename).parts
            if not bits or bits[0] != prefix or any(p in {"..", "."} for p in bits):
                raise RuntimeError("ZIP path")
            mode = e.external_attr >> 16
            if stat.S_ISLNK(mode) or "\\" in e.orig_filename or e.orig_filename != e.filename:
                raise RuntimeError("ZIP symlink or backslash")
            if e.is_dir():
                continue
            rel = "/".join(bits[1:])
            if not rel or rel in seen or ":" in rel or e.file_size > 64 * 1024 * 1024:
                raise RuntimeError("ZIP payload identity")
            if rel.casefold() in folded:
                raise RuntimeError("ZIP case-insensitive duplicate")
            seen.add(rel)
            folded.add(rel.casefold())
            total += e.file_size
            if total > cap:
                raise RuntimeError("ZIP decoded byte cap")
            if expected is not None and rel not in expected:
                raise RuntimeError("unexpected source payload: " + rel)
            output = destination.joinpath(*bits[1:])
            output.parent.mkdir(parents=True, exist_ok=True)
            if exact_raw_git and rel in RAW_GIT_ARCHIVE_EXCEPTIONS:
                original = z.read(e)
                row = expected[rel]
                normalized = original.replace(b"\r\n", b"\n")
                normalized_blob = hashlib.sha1(b"blob " + str(len(normalized)).encode("ascii") + b"\0" + normalized).hexdigest()
                if e.file_size != 2763 or len(normalized) != row["size"] or normalized_blob != row["sha"]:
                    raise RuntimeError("unexpected archive normalization exception")
                # Fetch original Git bytes; never manufacture normalized source.
                fetched = download("https://raw.githubusercontent.com/apromore/ApromoreCore/" + CORE + "/" + rel, output, 8192, RAW_BAT_SHA256)
                raw = output.read_bytes()
                if hashlib.sha1(b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw).hexdigest() != row["sha"]:
                    raise RuntimeError("raw Git replacement blob mismatch")
                replacements.append({"path": rel, "archive_bytes": e.file_size,
                                     "archive_sha256": hashlib.sha256(original).hexdigest(),
                                     "actual_raw_git_download": fetched})
                continue
            h = hashlib.sha1(b"blob " + str(e.file_size).encode("ascii") + b"\0")
            actual_size = 0
            with z.open(e) as source, output.open("xb") as out:
                while True:
                    guard()
                    b = source.read(1024 * 1024)
                    if not b:
                        break
                    actual_size += len(b)
                    h.update(b)
                    out.write(b)
            if actual_size != e.file_size:
                raise RuntimeError("decoded length mismatch")
            if expected is not None:
                row = expected[rel]
                if row["sha"] != h.hexdigest() or row["size"] != actual_size:
                    raise RuntimeError("source Git blob mismatch: " + rel)
    if expected is not None and seen != set(expected):
        raise RuntimeError("source tree missing files")
    return {"files": len(seen), "decoded_bytes": total, "zip_prefix": prefix,
            "all_git_blobs_verified": expected is not None,
            "exact_git_source_bytes": sum(e["size"] for e in expected.values()) if expected else None,
            "exact_raw_git_archive_replacements": replacements}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--tree", required=True)
    parser.add_argument("--existing-core-archive")
    parser.add_argument("--existing-core-sha256")
    args = parser.parse_args()
    out, tree_path = pathlib.Path(args.out).resolve(), pathlib.Path(args.tree).resolve()
    allowed = pathlib.Path(__file__).resolve().parents[2] / ".local" / "sprint16" / "service"
    if not out.is_relative_to(allowed.resolve()) or not out.parent.is_dir():
        raise RuntimeError("new private service attempt scope")
    if digest(tree_path) != TREE_SHA256:
        raise RuntimeError("exact pinned tree receipt")
    tree = json.loads(tree_path.read_text(encoding="utf-8-sig"))
    if tree["sha"] != TREE or tree["truncated"]:
        raise RuntimeError("complete exact tree required")
    expected = {e["path"]: e for e in tree["tree"] if e["type"] == "blob"}
    if len(expected) != 5763:
        raise RuntimeError("source count")
    out.mkdir()  # Existing attempt is never overwritten.
    source = out / "core-source.zip"
    gradle = out / "gradle-7.1.1-bin.zip"
    report = {"core_commit": CORE, "core_tree": TREE, "kind": "INPUT_PREPARATION_ONLY"}
    if args.existing_core_archive:
        previous = pathlib.Path(args.existing_core_archive).resolve()
        if not previous.is_relative_to(allowed.resolve()) or previous.stat().st_size > 128 * 1024 * 1024 or digest(previous) != args.existing_core_sha256:
            raise RuntimeError("exact prior private archive required")
        with previous.open("rb") as inp, source.open("xb") as output:
            while True:
                guard()
                b = inp.read(1024 * 1024)
                if not b:
                    break
                output.write(b)
        if digest(source) != args.existing_core_sha256:
            raise RuntimeError("prior archive copy mismatch")
        report["core_download"] = {"mode": "EXACT_ARCHIVE_REUSED_FROM_PRIOR_FAILED_PREPARATION",
                                   "sha256": digest(source), "bytes": source.stat().st_size,
                                   "new_download_claimed": False, "previous": str(previous)}
    else:
        report["core_download"] = download("https://codeload.github.com/apromore/ApromoreCore/zip/" + CORE, source, 128 * 1024 * 1024)
    report["source_extraction"] = extract(source, out / "source", expected, 128 * 1024 * 1024, exact_raw_git=True)
    report["gradle_download"] = download("https://services.gradle.org/distributions/gradle-7.1.1-bin.zip", gradle, 128 * 1024 * 1024, GRADLE_SHA)
    report["gradle_extraction"] = extract(gradle, out / "gradle", cap=256 * 1024 * 1024)
    report["utc"] = datetime.now(timezone.utc).isoformat()
    with (out / "bootstrap-proof.json").open("x", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report))


if __name__ == "__main__":
    main()
