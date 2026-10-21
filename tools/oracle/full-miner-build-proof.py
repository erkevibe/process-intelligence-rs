"""Record actual canonical build/runtime inputs and recheck unchanged source."""
import argparse
import hashlib
import json
import os
import pathlib
from datetime import datetime, timezone


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--tree", required=True)
    parser.add_argument("--classpath", required=True)
    parser.add_argument("--build-result", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    own = pathlib.Path(__file__).resolve().parents[2] / ".local" / "sprint16" / "service"
    source, cpfile = pathlib.Path(args.source).resolve(), pathlib.Path(args.classpath).resolve()
    if not source.is_relative_to(own) or not cpfile.is_relative_to(own):
        raise RuntimeError("private canonical paths")
    tree = json.loads(pathlib.Path(args.tree).read_text(encoding="utf-8-sig"))
    if tree["sha"] != "c9f89200ad1170a4aed9711b5174234e7ec2dc18" or tree["truncated"]:
        raise RuntimeError("exact complete source tree")
    result = json.loads(pathlib.Path(args.build_result).read_text(encoding="utf-8-sig"))
    if result["status"] != "COMMAND_COMPLETED" or result["native"]["native_exit"] != 0:
        raise RuntimeError("actual canonical build success required")
    originals = []
    for row in tree["tree"]:
        if row["type"] != "blob":
            continue
        p = source.joinpath(*pathlib.PurePosixPath(row["path"]).parts)
        b = p.read_bytes()
        if len(b) != row["size"] or hashlib.sha1(b"blob " + str(len(b)).encode("ascii") + b"\0" + b).hexdigest() != row["sha"]:
            raise RuntimeError("upstream source changed: " + row["path"])
        originals.append({"path": row["path"], "bytes": len(b), "git_blob": row["sha"]})
    files = {}
    entries = []
    for item in cpfile.read_text(encoding="utf-8-sig").split(os.pathsep):
        p = pathlib.Path(item).resolve()
        if not p.is_relative_to(own):
            raise RuntimeError("runtime classpath escaped isolated build")
        entries.append({"path": str(p), "exists": p.exists(), "directory": p.is_dir()})
        if p.is_dir():
            walk = p.rglob("*")
        elif p.is_file():
            walk = [p]
        else:
            if p.suffix.lower() in {".jar", ".class"}:
                raise RuntimeError("missing executable runtime artifact: " + str(p))
            continue  # Empty resource directories are legal Java classpath entries.
        for f in walk:
            if f.is_symlink() or f.is_junction():
                raise RuntimeError("runtime link")
            if not f.is_file():
                continue
            key = str(f.resolve())
            files[key] = {"path": key, "bytes": f.stat().st_size, "sha256": sha(f)}
            if len(files) > 30000:
                raise RuntimeError("runtime file cap")
    classfile = source / "Apromore-Custom-Plugins/SplitMiner-Logic/build/classes/java/main/org/apromore/splitminer/SplitMiner.class"
    if str(classfile.resolve()) not in files:
        raise RuntimeError("actual genuine SplitMiner class missing")
    build_inputs = []
    caches = own / "gradle-home" / "caches"
    for f in sorted(caches.rglob("*.jar")):
        if f.is_symlink() or f.is_junction():
            raise RuntimeError("build dependency link")
        build_inputs.append({"path": str(f.resolve()), "bytes": f.stat().st_size, "sha256": sha(f)})
    record = {"utc": datetime.now(timezone.utc).isoformat(), "status": "ACTUAL_CANONICAL_SPLITMINER_CLASSES_AND_RUNTIME_INPUTS_RECORDED",
              "original_source_files": len(originals), "unchanged_source": originals,
              "classpath_entries": entries, "runtime_files": sorted(files.values(), key=lambda x: x["path"]),
              "runtime_bytes": sum(f["bytes"] for f in files.values()), "build_dependency_jars": build_inputs,
              "runtime_classpath_sha256": sha(cpfile), "canonical_build_result_sha256": sha(pathlib.Path(args.build_result)),
              "miner_class_sha256": sha(classfile), "miner_class_bytes": classfile.stat().st_size,
              "scope": "Actual full unchanged SplitMiner classes and real Gradle/runtime dependencies; no algorithm invocation, graph quality or Rust port inferred"}
    with pathlib.Path(args.out).open("x", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
    print(json.dumps({"status": record["status"], "sources": len(originals), "runtime_files": len(files), "build_jars": len(build_inputs), "miner_class_sha256": record["miner_class_sha256"]}))


if __name__ == "__main__":
    main()
