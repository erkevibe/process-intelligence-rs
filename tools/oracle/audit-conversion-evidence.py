"""Independent finite conversion evidence audit; stdlib, data only, no converters.

The corpus supplies pre-implementation manual expectations. Actual payloads are
decoded independently; candidate summaries and claimed bijections are checked,
never used to choose the expected graph or event fields.
"""
import argparse
import collections
import csv
import datetime as dt
import hashlib
import io
import json
import pathlib
import re
import sys
import uuid
import xml.etree.ElementTree as ET

CORPUS_SHA256 = "621dc9106835eb3274659a08f033da4b74ef7cce9a58846e4b01788c866cfe34"
METHOD_SHA256 = "49dc32d1f4219965ea57cc79caa9355974269fab989cc38d09173c8e734e619b"


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def pairs(items):
    result = {}
    for key, value in items:
        need(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def loads(data):
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda value: need(False, "nonfinite JSON"))


def read(path, cap=20 * 1024 * 1024):
    path = pathlib.Path(path)
    need(path.is_file() and not path.is_symlink(), "regular file required")
    need(path.stat().st_size <= cap, "input cap")
    return path.read_bytes()


def local(base, name):
    need(isinstance(name, str), "path string")
    rel = pathlib.PurePosixPath(name.replace("\\", "/"))
    need(not rel.is_absolute() and ".." not in rel.parts and ":" not in name,
         "portable contained path required")
    result = pathlib.Path(base).joinpath(*rel.parts)
    need(result.resolve().is_relative_to(pathlib.Path(base).resolve()), "path escape")
    for parent in (result, *result.parents):
        if parent == pathlib.Path(base).parent:
            break
        need(not parent.is_symlink(), "symlink forbidden")
    return result


def xml(data):
    # Parse exactly the inspected UTF-8 text. ElementTree's bytes API can
    # autodetect UTF-16, which would bypass an ASCII-byte declaration scan.
    text = data.decode("utf-8")
    need("\x00" not in text, "XML NUL forbidden")
    need(not re.search(r"<!|<\?", text), "XML declaration/entity/PI forbidden")
    return ET.fromstring(text)


def instant(value):
    match = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)", value)
    need(match is not None, "timestamp lexical domain")
    body, fraction, zone = match.groups()
    base = dt.datetime.strptime(body, "%Y-%m-%dT%H:%M:%S")
    seconds = 0
    if zone != "Z":
        hour, minute = map(int, zone[1:].split(":"))
        need(hour <= 23 and minute <= 59, "offset domain")
        seconds = (hour * 3600 + minute * 60) * (1 if zone[0] == "+" else -1)
    utc = base - dt.timedelta(seconds=seconds)
    suffix = (fraction or "").rstrip("0")
    return utc.strftime("%Y-%m-%dT%H:%M:%S") + ("." + suffix if suffix else "") + "Z", seconds


def core(data, kind, strict_output=False):
    """Return ordered fields and independently inventoried omissions."""
    traces, losses = [], []
    if kind == "csv":
        rows = list(csv.reader(io.StringIO(data.decode("utf-8"), newline=""), strict=True))
        need(rows and rows[0][:4] == ["case", "activity", "timestamp", "lifecycle"], "CSV columns")
        need(len(set(rows[0])) == len(rows[0]), "CSV duplicate header")
        need(not strict_output or len(rows[0]) == 4, "target CSV extra columns")
        seen = set()
        for index, row in enumerate(rows[1:]):
            need(len(row) == len(rows[0]) and row[0] and row[1], "CSV shape")
            if not traces or traces[-1]["name"] != row[0]:
                need(row[0] not in seen, "CSV interleaved case")
                seen.add(row[0]); traces.append({"name": row[0], "events": []})
            timestamp = None
            if row[2]:
                timestamp, offset = instant(row[2])
                if offset:
                    losses.append({"kind": "timestamp_offset", "row": index,
                                   "column": "timestamp", "original": row[2],
                                   "offset_seconds": offset, "normalized": timestamp})
            traces[-1]["events"].append({"activity": row[1], "timestamp": timestamp,
                                         "lifecycle": row[3] or None})
            for column, cell in zip(rows[0][4:], row[4:]):
                if cell:
                    losses.append({"kind": "csv_extra_cell", "row": index,
                                   "column": column, "value": cell})
    else:
        root = xml(data)
        namespace = "{http://www.xes-standard.org/}"
        def name(element):
            return element.tag.removeprefix(namespace)
        need(name(root) == "log", "XES root")
        need(set(root.attrib) <= {"xes.version"}, "XES root fields")
        def fields(parent, scope, ti=None, ei=None):
            result = {}
            for item in parent:
                tag = name(item)
                if tag in ("trace", "event"):
                    continue
                if tag in ("extension", "classifier"):
                    need(scope == "log", "declaration scope")
                    losses.append({"kind": tag + "_declaration", "attributes": dict(item.attrib)})
                    continue
                need(tag in ("string", "date", "int", "float", "boolean"), "XES scalar domain")
                need(not list(item) and set(item.attrib) == {"key", "value"}, "XES scalar structure")
                key, value = item.attrib["key"], item.attrib["value"]
                need(key not in result, "duplicate XES field")
                result[key] = (tag, value)
                is_core = ((scope == "trace" and key == "concept:name") or
                           (scope == "event" and key in ("concept:name", "time:timestamp", "lifecycle:transition")))
                if not is_core:
                    loss = {"kind": "xes_scalar", "scope": scope, "key": key, "type": tag, "value": value}
                    if ti is not None: loss["trace"] = ti
                    if ei is not None: loss["event"] = ei
                    losses.append(loss)
            return result
        fields(root, "log")
        seen = set()
        for ti, trace in enumerate(e for e in root if name(e) == "trace"):
            need(not trace.attrib, "XES trace attributes")
            attrs = fields(trace, "trace", ti)
            need(attrs.get("concept:name", (None, None))[0] == "string", "trace name")
            trace_name = attrs["concept:name"][1]
            need(trace_name and trace_name not in seen, "trace identity")
            seen.add(trace_name)
            events = []
            for ei, event in enumerate(e for e in trace if name(e) == "event"):
                need(not event.attrib, "XES event attributes")
                attrs = fields(event, "event", ti, ei)
                need(attrs.get("concept:name", (None, None))[0] == "string", "event activity")
                activity = attrs["concept:name"][1]
                need(bool(activity), "empty activity")
                lifecycle = attrs.get("lifecycle:transition")
                need(lifecycle is None or lifecycle[0] == "string" and bool(lifecycle[1]), "lifecycle")
                timestamp = None
                if "time:timestamp" in attrs:
                    tag, value = attrs["time:timestamp"]
                    need(tag == "date", "timestamp type")
                    timestamp, offset = instant(value)
                    if offset:
                        losses.append({"kind": "timestamp_offset", "trace": ti, "event": ei,
                                       "original": value, "offset_seconds": offset, "normalized": timestamp})
                events.append({"activity": activity, "timestamp": timestamp,
                               "lifecycle": lifecycle[1] if lifecycle else None})
            need(bool(events), "empty trace")
            traces.append({"name": trace_name, "events": events})
    return {"traces": traces}, losses


def integer(value, maximum):
    need(type(value) is int and 0 <= value <= maximum, "integer bounds")
    return value


def graph(data, kind):
    if kind == "petri-json":
        obj = loads(data)
        need(set(obj) == {"places", "transitions", "arcs", "initial_marking", "final_markings"}, "native JSON keys")
        nodes = {}
        for key in ("places", "transitions"):
            for identity, node in obj[key].items():
                need(set(node) == ({"id"} if key == "places" else {"id", "label"}), "native node fields")
                need(identity not in nodes and node["id"] == identity, "native node identity")
                nodes[identity] = {"id": identity, "kind": "place" if key == "places" else "transition",
                                   "label": None if key == "places" else node["label"]}
        arcs = []
        for arc in obj["arcs"]:
            need(set(arc) == {"from_to", "weight"} and set(arc["from_to"]) == {"type", "nodes"}, "native arc fields")
            source, target = arc["from_to"]["nodes"]
            need(source in nodes and target in nodes, "native arc reference")
            expected_type = "PlaceTransition" if nodes[source]["kind"] == "place" else "TransitionPlace"
            need(arc["from_to"]["type"] == expected_type and nodes[source]["kind"] != nodes[target]["kind"], "arc partition")
            weight = integer(arc["weight"], 2**32 - 1); need(weight > 0, "positive arc")
            arcs.append({"source": source, "target": target, "weight": weight})
        initial, finals = obj["initial_marking"], obj["final_markings"]
    else:
        root = xml(data); need(root.tag == "pnml", "PNML root")
        need(not root.attrib, "PNML root attributes")
        nets = list(root); need(len(nets) == 1 and nets[0].tag == "net", "one PNML net")
        net = nets[0]; pages = net.findall("page"); need(len(pages) == 1, "one PNML page")
        need(set(net.attrib) == {"id", "type"} and net.attrib["type"] == "http://www.pnml.org/version-2009/grammar/pnmlcoremodel", "PNML net attributes")
        need(set(pages[0].attrib) == {"id"}, "PNML page attributes")
        need(all(item.tag in ("page", "finalmarkings") for item in net) and len(net.findall("finalmarkings")) <= 1, "PNML net children")
        nodes, arcs, initial = {}, [], {}
        def number(text, maximum):
            need(isinstance(text, str) and re.fullmatch(r"0|[1-9]\d*", text) is not None, "PNML numeric lexical")
            return integer(int(text), maximum)
        for node in pages[0]:
            if node.tag == "arc":
                need(set(node.attrib) == {"id", "source", "target"} and [item.tag for item in node] == ["inscription"], "PNML arc fields")
                inscription = node[0]
                need(not inscription.attrib and len(inscription) == 1 and inscription[0].tag == "text" and not inscription[0].attrib and not list(inscription[0]), "PNML inscription")
                arcs.append({"source": node.attrib["source"], "target": node.attrib["target"],
                             "weight": number(node.findtext("inscription/text"), 2**32 - 1)})
                continue
            need(node.tag in ("place", "transition"), "PNML node type")
            need(set(node.attrib) == {"id"}, "PNML node attributes")
            allowed = {"name", "initialMarking"} if node.tag == "place" else {"name", "toolspecific"}
            need(all(item.tag in allowed for item in node), "PNML unsupported node child")
            need(len({item.tag for item in node}) == len(node), "PNML duplicate child")
            for item in node:
                if item.tag != "toolspecific":
                    need(not item.attrib and len(item) == 1 and item[0].tag == "text" and not item[0].attrib and not list(item[0]), "PNML text shape")
            identity = node.attrib["id"]; need(identity not in nodes, "PNML duplicate node")
            if node.tag == "place":
                need(node.find("name") is None or node.findtext("name/text") == identity, "PNML unsupported place name")
            label = node.findtext("name/text") if node.tag == "transition" else None
            markers = node.findall("toolspecific")
            if markers:
                need(len(markers) == 1 and set(markers[0].attrib) == {"tool", "version", "activity", "localNodeID"} and markers[0].attrib["tool"] == "ProM" and markers[0].attrib["version"] == "6.4" and markers[0].attrib["activity"] == "$invisible$" and label == "Tau" and not list(markers[0]), "PNML tau marker")
                label = None
            nodes[identity] = {"id": identity, "kind": node.tag, "label": label}
            value = node.find("initialMarking/text")
            if value is not None:
                initial[identity] = number(value.text, 2**64 - 1)
        initial = initial or None
        final_node = net.find("finalmarkings")
        finals = None if final_node is None else []
        if final_node is not None:
            need(not final_node.attrib, "PNML final attributes")
            for marking in final_node:
                need(marking.tag == "marking" and not marking.attrib, "PNML marking shape")
                result = {}
                for place in marking:
                    need(place.tag == "place" and set(place.attrib) == {"idref"} and len(place) == 1 and place[0].tag == "text" and not place[0].attrib and not list(place[0]), "PNML final entry shape")
                    identity = place.attrib["idref"]; need(identity not in result, "duplicate final entry")
                    result[identity] = number(place.findtext("text"), 2**64 - 1)
                finals.append(result)
        for arc in arcs:
            need(arc["source"] in nodes and arc["target"] in nodes and arc["weight"] > 0, "PNML arc validity")
            need(nodes[arc["source"]]["kind"] != nodes[arc["target"]]["kind"], "PNML bipartite arc")
    for marking in ([] if initial is None else [initial]) + ([] if finals is None else finals):
        for identity, value in marking.items():
            need(identity in nodes and nodes[identity]["kind"] == "place", "marking place")
            integer(value, 2**64 - 1)
    need(len({(a["source"], a["target"]) for a in arcs}) == len(arcs), "duplicate arc")
    return {"nodes": nodes, "arcs": arcs, "initial": initial, "finals": finals}


def manual_graph(obj):
    nodes = {identity: {"id": identity, "kind": "place", "label": None} for identity in obj["places"]}
    nodes.update({row["id"]: {"id": row["id"], "kind": "transition", "label": row["label"]}
                  for row in obj["transitions"]})
    return {"nodes": nodes, "arcs": obj["arcs"], "initial": obj["initial"], "finals": obj["finals"]}


def mapped_equal(left, right, mapping):
    if set(mapping) != set(left["nodes"]) or set(mapping.values()) != set(right["nodes"]) or len(set(mapping.values())) != len(mapping):
        return False
    for identity, target in mapping.items():
        if (left["nodes"][identity]["kind"], left["nodes"][identity]["label"]) != (right["nodes"][target]["kind"], right["nodes"][target]["label"]):
            return False
    def arcs(value, rename):
        return sorted((rename[a["source"]], rename[a["target"]], a["weight"]) for a in value["arcs"])
    identity = {key: key for key in right["nodes"]}
    if arcs(left, mapping) != arcs(right, identity): return False
    def markings(value, rename):
        return None if value is None else {rename[k]: v for k, v in value.items()}
    if markings(left["initial"], mapping) != right["initial"]: return False
    if (left["finals"] is None) != (right["finals"] is None): return False
    return left["finals"] is None or [markings(m, mapping) for m in left["finals"]] == right["finals"]


def isomorphic(left, right):
    need(len(left["nodes"]) == len(right["nodes"]), "graph node count")
    def color(value, identity):
        node = value["nodes"][identity]
        def entry(marking):
            return None if marking is None else (identity in marking, marking.get(identity))
        return (node["kind"], node["label"], entry(value["initial"]),
                None if value["finals"] is None else tuple(entry(m) for m in value["finals"]),
                tuple(sorted(a["weight"] for a in value["arcs"] if a["source"] == identity)),
                tuple(sorted(a["weight"] for a in value["arcs"] if a["target"] == identity)))
    choices = {key: [other for other in right["nodes"] if color(left, key) == color(right, other)] for key in left["nodes"]}
    order = sorted(choices, key=lambda key: (len(choices[key]), key))
    counter = 0
    def search(mapping):
        nonlocal counter
        counter += 1; need(counter <= 100000, "independent bijection search inconclusive")
        if len(mapping) == len(order): return mapping.copy() if mapped_equal(left, right, mapping) else None
        key = order[len(mapping)]
        for other in choices[key]:
            if other not in mapping.values():
                mapping[key] = other
                found = search(mapping)
                if found is not None: return found
                del mapping[key]
        return None
    result = search({}); need(result is not None, "full graph/marking mismatch")
    return result


def simplify_loss(value):
    value = dict(value)
    location = value.pop("location", {})
    value = {key: item for key, item in value.items() if item is not None}
    value.update({key: item for key, item in location.items() if key != "byte_offset"})
    return value


def canonical_losses(values):
    return sorted(json.dumps(simplify_loss(value), sort_keys=True, ensure_ascii=False) for value in values)


def declarations(data, kind):
    if kind == "csv":
        headers = next(csv.reader(io.StringIO(data.decode("utf-8"), newline=""), strict=True))
        return {"format": "csv", "headers": headers, "delimiter": ",", "encoding": "UTF-8"}
    root = xml(data)
    namespaced = root.tag == "{http://www.xes-standard.org/}log"
    need(root.tag in ("log", "{http://www.xes-standard.org/}log"), "XES declarations root")
    return {"format": "xes",
            "xes.version": {"present": "xes.version" in root.attrib, "value": root.attrib.get("xes.version")},
            "xmlns": {"present": namespaced, "value": "http://www.xes-standard.org/" if namespaced else None}}


def lexical_normalizations(data, kind):
    values = []
    def observe(value, location):
        normalized, offset = instant(value)
        if offset == 0 and normalized != value:
            values.append({"kind": "timestamp_lexical", "location": location,
                           "original": value, "normalized": normalized})
    if kind == "csv":
        rows = list(csv.reader(io.StringIO(data.decode("utf-8"), newline=""), strict=True))
        for index, row in enumerate(rows[1:]):
            if row[2]: observe(row[2], {"row": index, "column": "timestamp"})
    else:
        root = xml(data)
        namespace = "{http://www.xes-standard.org/}" if root.tag.startswith("{") else ""
        for ti, trace in enumerate(root.findall(namespace + "trace")):
            for ei, event in enumerate(trace.findall(namespace + "event")):
                for item in event:
                    if item.attrib.get("key") == "time:timestamp":
                        observe(item.attrib["value"], {"trace": ti, "event": ei})
    return values


def log_report_integrity(evidence, source, source_kind, payload, target_kind, manual=None):
    expected = {"source": declarations(source, source_kind),
                "target": declarations(payload, target_kind), "metadata_loss_count": 0}
    need(evidence["format_declarations"] == expected, "actual source/target format declarations")
    normalizations = evidence["normalizations"]
    need(isinstance(normalizations, list), "normalization list")
    format_rows = [row for row in normalizations if row.get("kind") == "format_declarations"]
    need(format_rows == [dict(expected, kind="format_declarations")], "format normalization integrity")
    derived = lexical_normalizations(source, source_kind)
    reported = [row for row in normalizations if row.get("kind") == "timestamp_lexical"]
    need(canonical_losses(reported) == canonical_losses(derived), "derived timestamp lexical normalizations")
    loss_locations(reported, source, source_kind)
    if manual is not None and "timestamp_normalization_count" in manual:
        need(len(derived) == manual["timestamp_normalization_count"], "manual timestamp normalization count")
    other = [row for row in normalizations if row.get("kind") not in ("timestamp_lexical", "format_declarations")]
    if source_kind == "csv":
        headers = expected["source"]["headers"]
        extra = [{"kind": "csv_extra_columns_omitted", "columns": headers[4:]}] if len(headers) > 4 else []
    else:
        extra = []
    need(other == extra, "complete normalization inventory")


def net_inventory(source, source_kind, payload, mapping):
    """Derive occurrence provenance from parsed payloads, not report claims."""
    entries = []
    locations = {}
    for side, data, kind in (("source", source, source_kind), ("target", payload, "pnml" if source_kind == "petri-json" else "petri-json")):
        nodes = {}
        if kind == "petri-json":
            obj = loads(data)
            for family in ("places", "transitions"):
                for key, value in obj[family].items():
                    pointer = key.replace("~", "~0").replace("/", "~1")
                    nodes[str(uuid.UUID(key))] = ({"syntax": "json", "path": "/" + family + "/" + pointer + "/id"}, value["id"])
        else:
            root = xml(data)
            def walk(element, path, parent=None):
                locator = {"syntax": "xml", "path": path}
                category, value, attribute = None, None, None
                if element.tag in ("net", "page", "arc"):
                    category, value, attribute = element.tag + "_id", element.attrib["id"], "id"
                elif element.tag == "text" and parent == "name" and "/place[" in path:
                    category, value = "place_display_name", element.text or ""
                elif element.tag == "toolspecific":
                    category, value, attribute = "tau_local_node_id", element.attrib["localNodeID"], "localNodeID"
                if category:
                    if attribute: locator["attribute"] = attribute
                    entries.append({"kind": category, "side": side, "locator": locator,
                                    "original_value": value if side == "source" else None,
                                    "normalized_value": value if side == "target" else None,
                                    "action": "omitted_format_field" if side == "source" else "generated_format_field"})
                if element.tag in ("place", "transition") and parent == "page":
                    nodes[element.attrib["id"]] = ({"syntax": "xml", "path": path, "attribute": "id"}, element.attrib["id"])
                counts = collections.Counter()
                for child in element:
                    index = counts[child.tag]; counts[child.tag] += 1
                    walk(child, path + "/" + child.tag + "[" + str(index) + "]", element.tag)
            walk(root, "/pnml")
        locations[side] = nodes
    need(set(locations["source"]) == set(mapping) and set(locations["target"]) == set(mapping.values()), "inventory complete node locations")
    for before, after in mapping.items():
        loc, original = locations["source"][before]
        counterpart, normalized = locations["target"][after]
        entries.append({"kind": "node_id_bijection", "side": "source_to_target", "locator": loc,
                        "counterpart_locator": counterpart, "original_value": original, "normalized_value": normalized,
                        "source_graph_id": before, "target_graph_id": after, "changed": original != normalized,
                        "action": "identity_mapping" if original == normalized else "verified_id_renaming"})
    return {"schema_version": 1, "xml_path_indexing": "zero_based_siblings_per_element_name",
            "json_pointer_escaping": "RFC6901 ~0 and ~1",
            "value_scope": "actual decoded XML attribute/text or JSON string values; exact lexical bytes remain SHA-bound payloads",
            "entry_count": len(entries), "counts": dict(collections.Counter(item["kind"] for item in entries)), "entries": entries}


def net_report_integrity(evidence, source, kind, payload):
    expected = net_inventory(source, kind, payload, evidence["node_bijection"])
    actual = evidence["normalization_inventory"]
    need(set(actual) == set(expected), "net inventory fields")
    for key in expected:
        if key == "entries":
            encode = lambda item: json.dumps(item, ensure_ascii=False, sort_keys=True)
            need(sorted(map(encode, actual[key])) == sorted(map(encode, expected[key])), "actual net normalization occurrences/locators/values")
        else:
            need(actual[key] == expected[key], "net inventory " + key)
    need(evidence["normalizations"] == sorted(expected["counts"]), "net normalization category inventory")


def loss_locations(values, source, kind):
    if kind != "xes":
        return
    for value in values:
        offset = value.get("location", {}).get("byte_offset")
        need(type(offset) is int and 0 <= offset < len(source) and source[offset:offset + 1] == b"<", "loss byte location")


def native(base, name, code, capture_mode="full"):
    record_path = local(base, name)
    record = loads(read(record_path, 2 * 1024 * 1024))
    need(record["native_exit"] == code and record["stdout_complete"] and record["stderr_complete"], "native status/EOF")
    need(not any(record.get(key) for key in ("output_limit", "capture_fault", "drain_timeout")), "native capture fault")
    need(isinstance(record.get("pid"), int) and record.get("native_creation_utc"), "native identity")
    need(capture_mode in ("full", "public_metadata_projection"), "explicit native capture mode")
    if capture_mode == "full":
        need(record_path.name.endswith(".process.json"), "native record suffix")
        prefix = record_path.name[:-len(".process.json")]
        for stream in ("stdout", "stderr"):
            data = read(record_path.with_name(prefix + "." + stream), 8 * 1024 * 1024)
            need(digest(data).upper() == record[stream + "_sha256"].upper()
                 and len(data) == record[stream + "_bytes_persisted"], "actual native stream bytes")
    return record


def audit_run(base, row, source, from_kind, to_kind, expected_status, reason=None,
              executable_sha=None, identities=None, capture_mode="full"):
    need(read(local(base, row["input_path"])) == source, "actual chained input bytes")
    directory = local(base, row["output_directory"])
    report_data = read(directory / "report.json", 4 * 1024 * 1024)
    need(digest(report_data) == row["report_sha256"].lower(), "report hash")
    report = loads(report_data)
    need(report["schema_version"] == 1 and report["from"] == from_kind and report["to"] == to_kind, "report direction/schema")
    need(report["input_sha256"].lower() == digest(source) and report["input_bytes"] == len(source), "report source binding")
    need(report["status"] == expected_status and (reason is None or report["reason"] == reason), "frozen status/reason")
    record = native(base, row["native_record_path"], 0 if expected_status == "converted" else 2, capture_mode)
    if executable_sha is not None:
        need(record["program_sha256"].lower() == executable_sha.lower(), "actual converter executable binding")
    if identities is not None:
        identity = (record["pid"], record["native_creation_utc"])
        need(identity not in identities, "duplicate native invocation identity")
        identities.add(identity)
    if expected_status != "converted":
        need({path.name for path in directory.iterdir()} == {"report.json"}, "refusal published payload")
        need(report["payload_file"] is None and report["target_sha256"] is None and report["target_bytes"] is None, "refusal target metadata")
        return report, None
    filename = {"csv": "payload.csv", "xes": "payload.xes", "petri-json": "payload.json", "pnml": "payload.pnml"}[to_kind]
    need(report["payload_file"] == filename and {path.name for path in directory.iterdir()} == {"report.json", filename}, "output inventory")
    payload = read(directory / filename)
    need(digest(payload) == report["target_sha256"].lower() and len(payload) == report["target_bytes"], "payload hash/size")
    return report, payload


def audit(corpus_path, index_path):
    corpus_data = read(corpus_path, 4 * 1024 * 1024); corpus = loads(corpus_data)
    need(digest(corpus_data) == CORPUS_SHA256 and corpus["method_sha256"].lower() == METHOD_SHA256, "approved finite corpus/method identity")
    index = loads(read(index_path, 4 * 1024 * 1024)); base = pathlib.Path(index_path).parent
    need(index["schema_version"] == 1 and index["corpus_sha256"].lower() == digest(corpus_data), "corpus binding")
    method = corpus["method_sha256"].lower()
    need(index["method_sha256"].lower() == method, "method binding")
    fixtures = pathlib.Path(corpus_path).parent
    for file in corpus["files"]:
        data = read(local(fixtures, file["file"]))
        need(digest(data) == file["sha256"].lower() and len(data) == file["bytes"], "frozen fixture inventory")
    rows = {row["id"]: row for row in index["cases"]}
    need(len(rows) == len(index["cases"]) == len(corpus["cases"]) and set(rows) == {case["id"] for case in corpus["cases"]}, "complete unique frozen cases")
    executable_sha = index["converter_sha256"]
    need(isinstance(executable_sha, str) and re.fullmatch(r"[0-9a-fA-F]{64}", executable_sha) is not None, "converter hash shape")
    capture_mode = index.get("native_capture_mode", "full")
    results, identities = [], set()
    for case in corpus["cases"]:
        row = rows[case["id"]]; expected = case["expected"]; manual = expected["manual_semantics"] or {}
        source = read(local(fixtures, case["input"]))
        need(digest(source) == case["input_sha256"].lower() and len(source) == case["input_bytes"], "case input binding")
        report, payload = audit_run(base, row["forward"], source, case["from"], case["to"], expected["status"], expected["reason"], executable_sha, identities, capture_mode)
        need(report["method_sha256"].lower() == method and report["allow_metadata_loss"] is case["allow_metadata_loss"], "report policy/method")
        evidence = report.get("evidence", report.get("details", {}))
        if "metadata_loss_count" in manual:
            need(evidence.get("metadata_loss_count") == manual["metadata_loss_count"], "manual loss count")
        if expected["status"] == "loss_refused":
            _, losses = core(source, case["from"])
            need(canonical_losses(evidence["losses"]) == canonical_losses(losses), "refusal complete loss inventory")
            loss_locations(evidence["losses"], source, case["from"])
        if payload is not None:
            need(row.get("inverse") is not None, "missing actual inverse")
            inverse, restored = audit_run(base, row["inverse"], payload, case["to"], case["from"], "converted", executable_sha=executable_sha, identities=identities, capture_mode=capture_mode)
            need(inverse["method_sha256"].lower() == method and inverse["allow_metadata_loss"] is False, "inverse method/policy")
            if case["from"] in ("xes", "csv"):
                source_core, losses = core(source, case["from"])
                target_core, target_losses = core(payload, case["to"], strict_output=True)
                inverse_core, inverse_losses = core(restored, case["from"], strict_output=True)
                frozen = loads(read(local(fixtures, manual["core_file"])))
                need(source_core == target_core == inverse_core == frozen, "direct/manual/roundtrip ordered core mismatch")
                need(not target_losses and not inverse_losses, "inverse payload retained hidden metadata")
                need(evidence["source_core"] == source_core and evidence["target_core"] == target_core, "candidate core summaries")
                need(inverse["evidence"]["source_core"] == target_core and inverse["evidence"]["target_core"] == inverse_core and inverse["evidence"]["metadata_loss_count"] == 0 and inverse["evidence"]["losses"] == [], "inverse actual core/loss summaries")
                need(canonical_losses(evidence["losses"]) == canonical_losses(losses), "independent full loss inventory")
                loss_locations(evidence["losses"], source, case["from"])
                need(evidence["metadata_loss_count"] == len(losses), "independent loss count")
                need(evidence["trace_count"] == len(frozen["traces"]) and evidence["event_count"] == sum(len(t["events"]) for t in frozen["traces"]), "trace/event counts")
                log_report_integrity(evidence, source, case["from"], payload, case["to"], manual)
                log_report_integrity(inverse["evidence"], payload, case["to"], restored, case["from"])
                if case["to"] == "csv" and expected.get("direct_target_file"):
                    need(payload == read(local(fixtures, expected["direct_target_file"])), "exact manual CSV target")
            else:
                source_graph = graph(source, case["from"]); target_graph = graph(payload, case["to"])
                restored_graph = graph(restored, case["from"])
                frozen = manual_graph(loads(read(local(fixtures, manual["graph_file"]))))
                for value in (source_graph, target_graph, restored_graph): isomorphic(frozen, value)
                need(mapped_equal(source_graph, target_graph, evidence["node_bijection"]), "candidate full bijection")
                need(mapped_equal(source_graph, evidence["source_graph"], {key: key for key in source_graph["nodes"]}), "claimed source graph")
                need(mapped_equal(target_graph, evidence["target_graph"], {key: key for key in target_graph["nodes"]}), "claimed target graph")
                need(mapped_equal(target_graph, restored_graph, inverse["evidence"]["node_bijection"]), "inverse full bijection")
                need(mapped_equal(target_graph, inverse["evidence"]["source_graph"], {key: key for key in target_graph["nodes"]}), "inverse claimed source graph")
                need(mapped_equal(restored_graph, inverse["evidence"]["target_graph"], {key: key for key in restored_graph["nodes"]}), "inverse claimed target graph")
                need(evidence["metadata_loss_count"] == 0 and inverse["evidence"]["metadata_loss_count"] == 0, "no Petri metadata loss permitted")
                net_report_integrity(evidence, source, case["from"], payload)
                net_report_integrity(inverse["evidence"], payload, case["to"], restored)
        else:
            need(row.get("inverse") is None, "refusal inverse fiction")
        results.append({"id": case["id"], "status": expected["status"], "actual_inverse": payload is not None})
    return {"status": "INDEPENDENT_FINITE_CONVERSION_EVIDENCE_AUDIT_PASS", "corpus_sha256": digest(corpus_data),
            "method_sha256": method, "converter_sha256": executable_sha, "native_capture_mode": capture_mode,
            "native_stream_bytes_rechecked": capture_mode == "full", "case_count": len(results), "cases": results,
            "claim": "Independent direct payload/manual graph, loss and separately executed inverse checks; no engine execution or whole R5 acceptance."}


def audit_boundaries(index_path, executable_sha):
    """Independent expectations, never the producer's embedded expected fields."""
    index = loads(read(index_path, 4 * 1024 * 1024))
    base = pathlib.Path(index_path).parent
    need(index["schema_version"] == 1 and index["converter_sha256"].lower() == executable_sha.lower(), "boundary candidate identity")
    rows = {row["id"]: row for row in index["cases"]}
    need(set(rows) == {"B%02d" % n for n in range(1, 10)} and len(index["cases"]) == 9, "complete boundary cases")
    source = ('case,activity,timestamp,lifecycle\r\n'
              'case-external,"Review, café",2026-10-22T00:00:00.000000001Z,complete\r\n').encode("utf-8")
    spaces = b'case,activity,timestamp,lifecycle\r\none,   ,,\r\n'
    marker = b'must remain unchanged'
    frozen_core = {"traces": [{"name": "case-external", "events": [{"activity": "Review, café",
                    "timestamp": "2026-10-22T00:00:00.000000001Z", "lifecycle": "complete"}]}]}
    capture_mode = index.get("native_capture_mode", "full")
    identities, reports, payloads = set(), {}, {}
    for number in range(1, 10):
        identity = "B%02d" % number; row = rows[identity]
        need(row["from"] == ("xes" if number == 2 else "csv") and row["to"] == ("csv" if number == 2 else "xes"), "boundary direction")
        need(row["allow_metadata_loss"] is (number == 9), "boundary explicit policy")
        need(not row.get("timed_out_or_capture_stopped"), "boundary interrupted")
        directory = local(base, row["output_directory"])
        code = 0 if number <= 2 else (2 if number >= 8 else 1)
        record = native(base, row["native_record_path"], code, capture_mode)
        need(record["program_sha256"].lower() == executable_sha.lower(), "boundary native executable")
        key = (record["pid"], record["native_creation_utc"])
        need(key not in identities, "duplicate boundary invocation"); identities.add(key)
        if number in (1, 2, 8, 9):
            input_data = source if number == 1 else (payloads["B01"] if number == 2 else spaces)
            report_file = next((f for f in row["files"] if f["path"] == "report.json"), None)
            need(report_file is not None, "boundary report descriptor")
            run = dict(row, report_sha256=report_file["sha256"])
            reason = "production_xes_parser_refused" if number >= 8 else "lossless_core"
            report, payload = audit_run(base, run, input_data, row["from"], row["to"],
                                       "refused" if number >= 8 else "converted", reason,
                                       executable_sha=executable_sha, capture_mode=capture_mode)
            need(report["method_sha256"].lower() == METHOD_SHA256 and report["allow_metadata_loss"] is (number == 9), "boundary report method/policy")
            reports[identity], payloads[identity] = report, payload
            if number <= 2:
                need(core(payload, row["to"], strict_output=True) == (frozen_core, []), "novel direct payload fields")
                need(report["evidence"]["source_core"] == report["evidence"]["target_core"] == frozen_core, "novel actual core summaries")
                need(report["evidence"]["losses"] == [] and report["evidence"]["metadata_loss_count"] == 0, "novel metadata loss")
                log_report_integrity(report["evidence"], input_data, row["from"], payload, row["to"])
                if number == 2: need(payload == source, "novel exact separately executed CSV inverse")
            else:
                need(report.get("details", {}).get("original_error", {}).get("code") == "empty_activity", "actual unchanged production parser refusal")
        elif number == 3:
            need(read(local(base, row["input_path"])) == source, "no-overwrite input")
            need({p.name for p in directory.iterdir()} == {"keep.txt"} and read(directory / "keep.txt") == marker, "no-overwrite actual sentinel")
        else:
            need(not directory.exists(), "boundary unexpected output directory")
            input_path = local(base, row["input_path"])
            if number == 4:
                data = read(input_path, 20 * 1024 * 1024 + 1)
                need(len(data) == 20 * 1024 * 1024 + 1 and not any(data), "actual oversized input bytes")
            elif number == 5: need(not input_path.exists(), "actual absent input")
            elif number == 6: need(input_path.is_dir(), "actual directory input")
            elif number == 7:
                need(read(input_path) == source and not directory.parent.exists(), "actual absent output parent not created")
    need(index["external_input_sha256"].lower() == digest(source), "novel source SHA")
    return {"status": "INDEPENDENT_EXTERNAL_BOUNDARIES_PASS", "case_count": 9,
            "native_capture_mode": capture_mode, "native_stream_bytes_rechecked": capture_mode == "full",
            "independent_expected_core": frozen_core, "external_input_sha256": digest(source),
            "claim": "Nine independently specified arbitrary-input/refusal/no-overwrite observations; original57 unchanged."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True); parser.add_argument("--index", required=True)
    parser.add_argument("--boundary-index")
    parser.add_argument("--output", required=True); args = parser.parse_args()
    result = audit(args.corpus, args.index)
    if args.boundary_index:
        result["external_boundaries"] = audit_boundaries(args.boundary_index, result["converter_sha256"])
    with open(args.output, "x", encoding="utf-8", newline="\n") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2); stream.write("\n")


if __name__ == "__main__":
    main()
