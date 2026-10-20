"""New two-case disambiguation corpus; original20 and expectations stay frozen."""
import hashlib
import json
import pathlib

out = pathlib.Path(__file__).resolve().parents[2] / "fixtures" / "oracle-full-service" / "supplement-nested"
out.mkdir()
cases = []
samples = {
    "list-only": '<list key="costs"><values><int key="item" value="3"/><int key="item" value="7"/></values></list>',
    "nested-literal": '<string key="cost_label" value="USD"><string key="unit" value="dollar"/></string>',
}
for name, extra in samples.items():
    data = ('<?xml version="1.0" encoding="UTF-8"?><log xmlns="http://www.xes-standard.org/"><string key="concept:name" value="Supplement"/><trace><string key="concept:name" value="case-1"/><event><string key="concept:name" value="A"/><date key="time:timestamp" value="2024-01-01T00:00:00Z"/>' + extra + '</event></trace></log>\n').encode()
    filename = name + ".xes"
    (out / filename).write_bytes(data)
    cases.append({"id": name, "file": filename, "extension": "xes", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                  "expected_service": {"outcome": "success", "traces": 1, "events": 1},
                  "purpose": "Separate successful typed containment from original mixed list+container upstream refusal",
                  "typed_manual_expectation": {"target_key": "costs", "type": "list", "ordered_values": [3, 7]} if name == "list-only" else {"target_key": "cost_label", "type": "string", "value": "USD", "children": [{"key": "unit", "type": "string", "value": "dollar"}]}})
manifest = {"schema_version": 1, "scope": "Supplement frozen after original20 observation, before supplemental execution",
            "original_corpus_sha256": "3af07e2094abd0a91cb6bbbe0e152dc9341ca40e75c3b238b6db1ec0b30abf60",
            "derived_from_actual_original_report_sha256": "13bbea23275ea851087051db44da8db5960e95b534755bb85c80db1a84189562",
            "original_manual_mismatches_retained": ["nested-attributes", "unknown-extension-fallback"], "corpus": cases}
with (out / "corpus.json").open("x", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps({"cases": len(cases), "manifest_sha256": hashlib.sha256((out / "corpus.json").read_bytes()).hexdigest()}))
