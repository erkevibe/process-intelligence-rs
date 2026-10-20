"""Create the finite S16 original-importer corpus once, before Java execution."""
import gzip
import hashlib
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[2]
out = root / "fixtures" / "oracle-full-service"
out.mkdir()  # Never silently rewrite frozen inputs.


def event(name="A", timestamp="2024-01-01T00:00:00Z", lifecycle=None, extra=""):
    n = "" if name is None else '<string key="concept:name" value="' + name + '"/>'
    t = "" if timestamp is None else '<date key="time:timestamp" value="' + timestamp + '"/>'
    life = "" if lifecycle is None else '<string key="lifecycle:transition" value="' + lifecycle + '"/>'
    return "<event>" + n + t + life + extra + "</event>"


def xes(events, header="", trace_attrs='<string key="concept:name" value="case-α"/>', name="S16 log"):
    log_name = "" if name is None else '<string key="concept:name" value="' + name + '"/>'
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<log xes.version="1.0" xes.features="nested-attributes" xmlns="http://www.xes-standard.org/">'
            + log_name + header + "<trace>" + trace_attrs + events + "</trace></log>\n").encode("utf-8")


rows = []


def add(case_id, data, expected, purpose, extension="xes", gzip_input=False):
    filename = case_id + ("." + extension if extension != "unknown" else ".data")
    if gzip_input:
        data = gzip.compress(data, mtime=0)
    (out / filename).write_bytes(data)
    rows.append({"id": case_id, "file": filename, "extension": extension,
                 "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                 "expected_service": expected, "purpose": purpose,
                 "selected_path": "UNCHANGED_FULL_CLASS_PRIVATE_importFromStream_WITH_REAL_DEFAULT_FACTORY",
                 "public_importLog_executed": False})


ok = lambda traces, events: {"outcome": "success", "traces": traces, "events": events}
add("default-log-name", xes(event(), name=None),
    {**ok(1, 1), "log_name": "Anonymous log imported from "}, "Exact original service default log-name; missing lifecycle becomes complete")
add("empty-log", b'<log xmlns="http://www.xes-standard.org/"/>',
    {"outcome": "refusal", "message": "No process instances contained in log!"}, "Pre-validation empty log sanity refusal")
add("empty-trace", xes(""), ok(0, 0), "Nonempty parsed log becomes empty after validateLog removes empty trace")
add("all-filtered", xes(event(timestamp=None) + event("B", lifecycle="suspend")), ok(0, 0), "Missing timestamp and unsupported lifecycle removed; no usable mining result inferred")
add("lifecycle", xes(event("A") + event("B", lifecycle="START") + event("C", lifecycle="complete") + event("D", lifecycle="suspend") + event("E", lifecycle=" complete ") + event("F", extra='<int key="lifecycle:transition" value="7"/>')),
    {**ok(1, 3), "activities": ["A", "B", "C"]}, "Missing default, case-insensitivity, whitespace and nonliteral lifecycle")
add("reverse-ties", xes(event("B", "2024-01-01T00:00:02Z") + event("A", "2024-01-01T00:00:01Z") + event("C", "2024-01-01T00:00:01Z")),
    {**ok(1, 3), "activities": ["B", "A", "C"]}, "Original XML order preserved, no adapter timestamp sort")
add("submillisecond", xes(event(timestamp="2024-01-01T00:00:00.123456Z")),
    {**ok(1, 1), "timestamp_millis": [1704067200123]}, "Java Date millisecond projection explicitly differs from Rust submillisecond precision")
add("offset-equivalent", xes(event("A", "2024-01-01T05:00:00+05:00") + event("B", "2024-01-01T00:00:00Z")),
    {**ok(1, 2), "timestamp_millis": [1704067200000, 1704067200000]}, "Equivalent offsets and stable source order")
add("typed-flat-attributes", xes(event(extra='<string key="org:resource" value="Алия"/><int key="attempt" value="-42"/><float key="cost" value="1.25"/><boolean key="approved" value="false"/><id key="identity:id" value="11111111-1111-4111-8111-111111111111"/>'),
    header='<int key="log:revision" value="4"/>', trace_attrs='<string key="concept:name" value="case-α"/><boolean key="vip" value="true"/>'),
    ok(1, 1), "Full typed custom attributes at log/trace/event scopes; loss must be explicit")
add("classifiers-extensions", xes(event(extra='<string key="org:resource" value="worker"/>'),
    header='<extension name="Concept" prefix="concept" uri="http://www.xes-standard.org/concept.xesext"/><extension name="Time" prefix="time" uri="http://www.xes-standard.org/time.xesext"/><classifier name="Activity lifecycle" keys="concept:name lifecycle:transition"/><classifier name="Resource" keys="org:resource"/>'),
    {**ok(1, 1), "classifiers": 2}, "Preserve classifier name/key arrays and extension declarations; do not flatten silently")
add("globals-not-event-values", xes('<event/>', header='<global scope="trace"><string key="concept:name" value="global-case"/></global><global scope="event"><string key="concept:name" value="global-event"/><date key="time:timestamp" value="2024-01-01T00:00:00Z"/></global>', trace_attrs=""),
    ok(0, 0), "Global declarations are metadata, not automatically materialized per-event mandatory keys")
add("duplicate-semantic-name", xes(event(extra='<string key="concept:name" value="B"/>')),
    {**ok(1, 1), "activities": ["B"]}, "Original parser last-key wins versus Rust strict duplicate-key admission")
add("wrong-timestamp-type", xes(event(timestamp=None, extra='<string key="time:timestamp" value="2024-01-01T00:00:00Z"/>')),
    ok(1, 1), "Original validate checks key presence; preserve actual string type, do not invent Date")
add("wrong-activity-type", xes(event(name=None, extra='<int key="concept:name" value="42"/>')),
    ok(1, 1), "Original validate keeps typed activity by presence; Rust admission remains explicit")
add("nested-attributes", xes(event(extra='<list key="costs"><values><int key="item" value="3"/><int key="item" value="7"/></values></list><container key="address"><string key="city" value="Алматы"/></container>')),
    ok(1, 1), "List ordering and nested attribute containment require full typed observer")
add("xes-gzip", xes(event()), ok(1, 1), "Real XesXmlGZIPParser dispatch", extension="xes.gz", gzip_input=True)
add("unknown-extension-fallback", xes(event()), ok(1, 1), "Default assertions disabled; null selected parser enters actual registry fallback on unconsumed stream", extension="unknown")
add("wrong-parser-consumed-stream", xes(event()), {"outcome": "refusal"}, "MXML selection on XES input; actual fallback reuses same stream and must not be rewound by adapter", extension="mxml")
mxml = b'''<?xml version="1.0" encoding="UTF-8"?><WorkflowLog description="S16"><Source program="S16"/><Process id="S16 process"><ProcessInstance id="case-1"><AuditTrailEntry><WorkflowModelElement>A</WorkflowModelElement><EventType>complete</EventType><Timestamp>2024-01-01T00:00:00Z</Timestamp><Originator>worker</Originator></AuditTrailEntry></ProcessInstance></Process></WorkflowLog>'''
add("mxml-dispatch", mxml, ok(1, 1), "Real XMxmlParser import path; Rust XES-only refusal is declared", extension="mxml")
add("mxml-gzip-dispatch", mxml, ok(1, 1), "Real XMxmlGZIPParser import path", extension="mxml.gz", gzip_input=True)
manifest = {"schema_version": 1, "scope": "Finite unchanged full-class private importer path, not public authenticated/persistent importLog", "assertions": "disabled explicitly, matching ordinary Java default", "corpus": rows}
with (out / "corpus.json").open("x", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
print(json.dumps({"cases": len(rows), "manifest_sha256": hashlib.sha256((out / "corpus.json").read_bytes()).hexdigest()}))
