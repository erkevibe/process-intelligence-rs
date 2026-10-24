"""Actual-data corruption controls; no converter, engine or subprocess execution.

Every clone and refusal receipt is retained. Payload/report/index hashes are
rebound so the intended independent semantic gate, not a stale digest, refuses.
"""
import argparse
import copy
import csv
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("conversion_auditor", ROOT / "tools/oracle/audit-conversion-evidence.py")
A = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(A)


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_report(base, run):
    path = A.local(base, run["output_directory"]) / "report.json"
    return path, A.loads(path.read_bytes())


def save_report(path, report, run):
    save(path, report)
    run["report_sha256"] = A.digest(path.read_bytes())


def payload_path(base, run, report):
    return A.local(base, run["output_directory"]) / report["payload_file"]


def replace_payload(base, run, data, summary=None):
    path, report = load_report(base, run)
    payload_path(base, run, report).write_bytes(data)
    report["target_sha256"], report["target_bytes"] = A.digest(data), len(data)
    if summary is not None:
        report["evidence"]["target_core" if "source_core" in report["evidence"] else "target_graph"] = summary
    save_report(path, report, run)


def rebind_inverse(base, inverse, data, summary=None):
    path, report = load_report(base, inverse)
    report["input_sha256"], report["input_bytes"] = A.digest(data), len(data)
    if summary is not None:
        report["evidence"]["source_core" if "source_core" in report["evidence"] else "source_graph"] = summary
    save_report(path, report, inverse)


def row(index, identity):
    return next(value for value in index["cases"] if value["id"] == identity)


def edit_core(base, index):
    case = row(index, "X01")
    _, report = load_report(base, case["forward"])
    original = payload_path(base, case["forward"], report).read_bytes()
    rows = list(csv.reader(io.StringIO(original.decode("utf-8"), newline="")))
    rows[1][1] = "ALTERED_ACTIVITY"
    stream = io.StringIO(newline=""); writer = csv.writer(stream, lineterminator="\r\n"); writer.writerows(rows)
    data = stream.getvalue().encode("utf-8")
    changed = A.core(data, "csv")[0]
    replace_payload(base, case["forward"], data, changed)
    rebind_inverse(base, case["inverse"], data, changed)
    _, inverse = load_report(base, case["inverse"])
    tree = ET.fromstring(payload_path(base, case["inverse"], inverse).read_bytes())
    for trace in tree:
        if trace.tag.endswith("trace"):
            for event in trace:
                if event.tag.endswith("event"):
                    next(item for item in event if item.attrib.get("key") == "concept:name").set("value", "ALTERED_ACTIVITY")
                    data = ET.tostring(tree, encoding="utf-8")
                    replace_payload(base, case["inverse"], data, A.core(data, "xes")[0])
                    return
    raise ValueError("positive source event absent")


def edit_declarations(base, index):
    run = row(index, "X01")["forward"]
    path, report = load_report(base, run)
    report["evidence"]["format_declarations"]["source"]["xmlns"] = {"present": False, "value": None}
    for item in report["evidence"]["normalizations"]:
        if item["kind"] == "format_declarations":
            item["source"]["xmlns"] = {"present": False, "value": None}
    save_report(path, report, run)


def edit_normalization(base, index):
    run = row(index, "X01")["forward"]
    path, report = load_report(base, run)
    report["evidence"]["normalizations"].append({"kind": "timestamp_lexical", "original": "2026-10-22T01:02:03.123456789+00:00", "normalized": "2026-10-22T01:02:03.123456789Z", "location": {"trace": 0, "event": 0, "byte_offset": 0}})
    save_report(path, report, run)


def maximum_initial_marking(tree):
    candidates = [(place, place.find("initialMarking/text")) for place in tree.findall("net/page/place")]
    matches = [(place, item) for place, item in candidates if item is not None and int(item.text) == (1 << 64) - 1]
    A.need(len(matches) == 1, "exactly one actual u64 maximum initial marking")
    return matches[0]


def edit_net(base, index, tokens=False):
    case = row(index, "P23" if tokens else "P01")
    _, report = load_report(base, case["forward"])
    tree = ET.fromstring(payload_path(base, case["forward"], report).read_bytes())
    if tokens:
        place, item = maximum_initial_marking(tree)
        place_id = place.attrib["id"]
        item.text = str(int(item.text) - 1)
    else:
        arc = tree.find("net/page/arc")
        item = arc.find("inscription/text"); item.text = str(int(item.text) + 1)
        source, target = arc.attrib["source"], arc.attrib["target"]
    data = ET.tostring(tree, encoding="utf-8")
    target_graph = A.graph(data, "pnml")
    replace_payload(base, case["forward"], data, target_graph)
    rebind_inverse(base, case["inverse"], data, target_graph)
    _, inverse = load_report(base, case["inverse"])
    obj = A.loads(payload_path(base, case["inverse"], inverse).read_bytes())
    mapping = inverse["evidence"]["node_bijection"]
    if tokens:
        obj["initial_marking"][mapping[place_id]] = int(item.text)
    else:
        selected = next(a for a in obj["arcs"] if a["from_to"]["nodes"] == [mapping[source], mapping[target]])
        selected["weight"] = int(item.text)
    data = (json.dumps(obj, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    replace_payload(base, case["inverse"], data, A.graph(data, "petri-json"))


def edit_inverse(base, index):
    inverse = row(index, "X01")["inverse"]
    _, report = load_report(base, inverse)
    tree = ET.fromstring(payload_path(base, inverse, report).read_bytes())
    trace = next(item for item in tree if item.tag.endswith("trace"))
    trace.remove([item for item in trace if item.tag.endswith("event")][-1])
    data = ET.tostring(tree, encoding="utf-8")
    replace_payload(base, inverse, data, A.core(data, "xes")[0])


def duplicate_process(base, index):
    first = row(index, "X01")["forward"]
    second = row(index, "X02")["forward"]
    original = A.loads(A.read(A.local(base, first["native_record_path"])))
    path = A.local(base, second["native_record_path"]); value = A.loads(A.read(path))
    value["pid"], value["native_creation_utc"] = original["pid"], original["native_creation_utc"]
    save(path, value)


def edit_namespace(base, index):
    case = row(index, "P01"); _, report = load_report(base, case["forward"])
    tree = ET.fromstring(payload_path(base, case["forward"], report).read_bytes())
    tree.find("net/page/transition").set("{urn:unrecorded-semantics}constraint", "hidden")
    data = ET.tostring(tree, encoding="utf-8")
    replace_payload(base, case["forward"], data)
    rebind_inverse(base, case["inverse"], data)


def edit_loss(base, index):
    run = row(index, "X06")["forward"]; path, report = load_report(base, run)
    report["evidence"]["losses"][0]["value"] = "HIDDEN_OMISSION"
    save_report(path, report, run)


def edit_net_inventory(base, index, phantom=False):
    run = row(index, "P01")["forward"]; path, report = load_report(base, run)
    inventory = report["evidence"]["normalization_inventory"]
    if phantom:
        entry = copy.deepcopy(next(item for item in inventory["entries"] if item["kind"] == "tau_local_node_id"))
        entry["locator"]["path"] = "/pnml/net[0]/page[0]/transition[999]/toolspecific[0]"
        inventory["entries"].append(entry)
        inventory["entry_count"] += 1
        inventory["counts"]["tau_local_node_id"] += 1
    else:
        inventory["entries"][0]["normalized_value"] = "not_the_actual_format_identifier"
    save_report(path, report, run)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--boundary-index", type=Path)
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()
    # The zero-first order reproduces the historical mutation-construction bug.
    control = ET.fromstring('<pnml><net><page><place id="zero"><initialMarking><text>0</text></initialMarking></place><place id="max"><initialMarking><text>18446744073709551615</text></initialMarking></place></page></net></pnml>')
    selected, value = maximum_initial_marking(control)
    A.need(selected.attrib["id"] == "max" and int(value.text) - 1 == 18446744073709551614, "zero-first maximum mutation control")
    source = args.index.parent.resolve(); output = args.output_directory.resolve()
    A.need(not output.exists() and not output.is_relative_to(source) and not source.is_relative_to(output), "new separate clone directory")
    files = list(source.rglob("*"))
    A.need(len(files) <= 10000 and not any(p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction()) for p in files), "bounded regular source tree")
    A.need(sum(p.stat().st_size for p in files if p.is_file()) <= 128 * 1024 * 1024, "clone byte cap")
    baseline = A.audit(args.corpus, args.index)
    if args.boundary_index:
        baseline["external_boundaries"] = A.audit_boundaries(args.boundary_index, baseline["converter_sha256"])
    output.mkdir(); save(output / "baseline.json", baseline)
    original = A.loads(args.index.read_bytes())
    mutations = [("core_and_inverse", edit_core), ("declarations", edit_declarations),
                 ("normalization", edit_normalization), ("weighted_arc", edit_net),
                 ("full_u64", lambda base, index: edit_net(base, index, True)),
                 ("inverse_event_loss", edit_inverse), ("duplicate_process", duplicate_process),
                 ("unknown_namespace", edit_namespace), ("hidden_loss", edit_loss),
                 ("net_inventory_value", edit_net_inventory),
                 ("net_inventory_phantom", lambda base, index: edit_net_inventory(base, index, True))]
    results = []
    for name, mutate in mutations:
        directory = output / name; shutil.copytree(source, directory, symlinks=True)
        index = copy.deepcopy(original); mutate(directory, index)
        index_path = directory / args.index.name; save(index_path, index)
        try:
            A.audit(args.corpus, index_path)
        except (ValueError, ET.ParseError, UnicodeError) as error:
            result = {"control": name, "refused": True, "reason": str(error),
                      "original_index_sha256": A.digest(args.index.read_bytes()),
                      "modified_index_sha256": A.digest(index_path.read_bytes()),
                      "payload_report_hashes_rebound": name != "duplicate_process"}
            save(output / (name + "-refusal.json"), result); results.append(result)
        else:
            save(output / (name + "-unexpected-pass.json"), {"control": name, "unexpected_pass": True})
            raise ValueError("counterfactual unexpectedly passed: " + name)
    save(output / "result.json", {"status": "ACTUAL_DATA_COUNTERFACTUALS_PASS", "controls": results,
                                  "clone_bytes_rewritten_not_converter_runs": True})
    print(json.dumps({"status": "ACTUAL_DATA_COUNTERFACTUALS_PASS", "controls": len(results)}))


if __name__ == "__main__":
    main()
