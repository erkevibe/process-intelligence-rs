"""Create a separate exact Git source tree; never copy or modify R2 build outputs."""
import argparse
import hashlib
import json
import pathlib
import shutil
from datetime import datetime, timezone

p = argparse.ArgumentParser()
p.add_argument("--source", required=True)
p.add_argument("--tree", required=True)
p.add_argument("--destination", required=True)
p.add_argument("--proof", required=True)
a = p.parse_args()
own = pathlib.Path(__file__).resolve().parents[2] / ".local" / "sprint16" / "service"
source, target = pathlib.Path(a.source).resolve(), pathlib.Path(a.destination).resolve()
if not source.is_relative_to(own) or not target.is_relative_to(own) or target.exists():
    raise RuntimeError("new isolated miner source required")
tree_path = pathlib.Path(a.tree)
if hashlib.sha256(tree_path.read_bytes()).hexdigest() != "bce30c8d971da259d4947f7ae9db904765dc1e980f5b9d41ccd86567a45fd96f":
    raise RuntimeError("exact pinned full tree")
tree = json.loads(tree_path.read_text(encoding="utf-8-sig"))
target.mkdir()
count = size = 0
for row in tree["tree"]:
    if row["type"] != "blob":
        continue
    if datetime.now(timezone.utc).timestamp() >= datetime(2026, 10, 20, 19, 46, 17, tzinfo=timezone.utc).timestamp() or shutil.disk_usage(own).free < 8 * 1024**3:
        raise RuntimeError("deadline or disk floor")
    rel = pathlib.PurePosixPath(row["path"])
    if rel.is_absolute() or ".." in rel.parts:
        raise RuntimeError("source path")
    src, dst = source.joinpath(*rel.parts), target.joinpath(*rel.parts)
    b = src.read_bytes()
    if len(b) != row["size"] or hashlib.sha1(b"blob " + str(len(b)).encode("ascii") + b"\0" + b).hexdigest() != row["sha"]:
        raise RuntimeError("original source no longer matches Git: " + row["path"])
    dst.parent.mkdir(parents=True, exist_ok=True)
    with dst.open("xb") as f:
        f.write(b)
    count += 1
    size += len(b)
if count != 5763 or size != 79393964:
    raise RuntimeError("exact full tree count/bytes")
proof = {"utc": datetime.now(timezone.utc).isoformat(), "status": "NEW_MINER_SOURCE_ONLY_EXACT_GIT_COPY", "source": str(source), "destination": str(target), "files": count, "bytes": size, "core_commit": "bbf24dfd43e72d6992392465f875a4367cbe792b", "copied_build_outputs": False, "old_r2_mutations": 0}
with pathlib.Path(a.proof).open("x", encoding="utf-8") as f:
    json.dump(proof, f, indent=2)
print(json.dumps(proof))
