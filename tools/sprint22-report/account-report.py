"""Read-only exact JSON value-span accounting of the accepted fixed 10k report.

No serialization of parsed values is used for byte accounting. raw_decode gives
character spans; strict UTF-8 encoding of those original source slices supplies
byte spans. Nested evidence children are a second level, not additive to top.
Root alone executes this pure saved-file observer after independent review.
"""
import hashlib
import json
import re
import sys
import time
from pathlib import Path

REPORT_SHA = "6E49BE8C6FC36C602B9CB30BBF7F8B11A68E90256FCDACB7431C26ABA3A8F9BE"
REPORT_BYTES = 3222364
MAX_BYTES = 4*1024*1024


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


DECODER = json.JSONDecoder(object_pairs_hook=unique,
                           parse_constant=lambda x: (_ for _ in ()).throw(ValueError("non-JSON number")))


def spans(text, begin, deadline):
    """Return exact direct object-child value character spans and object end."""
    def ws(i):
        while i < len(text) and text[i] in " \t\r\n":
            i += 1
        return i

    i = ws(begin)
    if i >= len(text) or text[i] != "{":
        raise ValueError("object required")
    i = ws(i+1)
    result = []
    seen = set()
    if text[i:i+1] == "}":
        return result, i+1
    while True:
        if len(result) >= 64 or time.monotonic() >= deadline:
            raise ValueError("finite key/time limit")
        key, key_end = DECODER.raw_decode(text, i)
        if type(key) is not str or key in seen:
            raise ValueError("unique string member required")
        seen.add(key)
        i = ws(key_end)
        if text[i:i+1] != ":":
            raise ValueError("colon required")
        value_start = ws(i+1)
        value, value_end = DECODER.raw_decode(text, value_start)
        result.append((key, value_start, value_end, value))
        i = ws(value_end)
        if text[i:i+1] == "}":
            return result, i+1
        if text[i:i+1] != ",":
            raise ValueError("comma required")
        i = ws(i+1)


def measured(text, values):
    rows = []
    for key, start, end, _ in values:
        # These bytes are original source syntax, including internal whitespace,
        # escape spellings, and numeric lexemes. Never json.dumps(value).
        raw = text[start:end].encode("utf-8")
        offset = len(text[:start].encode("utf-8"))
        rows.append({"key": key, "start_byte": offset,
                     "end_byte_exclusive": offset+len(raw),
                     "value_utf8_bytes": len(raw),
                     "raw_value_sha256": hashlib.sha256(raw).hexdigest().upper()})
    return rows


def fixtures(deadline):
    raw = b' { "escaped": "\\u00e9", "literal": "\xc3\xa9", "number": 1e+02, "object": { "n" : 2 }, "array": [true, null] } \n'
    text = raw.decode("utf-8")
    values, end = spans(text, 0, deadline)
    assert not text[end:].strip()
    rows = {r["key"]: r for r in measured(text, values)}
    expected = {"escaped": b'"\\u00e9"', "literal": b'"\xc3\xa9"',
                "number": b'1e+02', "object": b'{ "n" : 2 }', "array": b'[true, null]'}
    for key, source in expected.items():
        row = rows[key]
        assert raw[row["start_byte"]:row["end_byte_exclusive"]] == source
        assert row["value_utf8_bytes"] == len(source)
    assert rows["escaped"]["value_utf8_bytes"] == 8
    assert rows["literal"]["value_utf8_bytes"] == 4
    assert dict((k, v) for k, _, _, v in values)["escaped"] == "é"
    assert dict((k, v) for k, _, _, v in values)["literal"] == "é"
    nested_start = next(s for k, s, _, _ in values if k == "object")
    nested, _ = spans(text, nested_start, deadline)
    assert text[nested[0][1]:nested[0][2]] == "2"
    unicode_text = b'{"e": {"v":"\xc3\xa9"}}'.decode("utf-8")
    unicode_top, _ = spans(unicode_text, 0, deadline)
    unicode_start, unicode_end = unicode_top[0][1:3]
    unicode_nested, _ = spans(unicode_text, unicode_start, deadline)
    unicode_container_bytes = len(unicode_text[unicode_start:unicode_end].encode("utf-8"))
    assert unicode_container_bytes == 10
    unicode_child_bytes = sum(r["value_utf8_bytes"] for r in measured(unicode_text, unicode_nested))
    assert unicode_child_bytes == 4 and unicode_container_bytes-unicode_child_bytes == 6
    for invalid in ('{"a":1,"a":2}', '{"a":1,}', '{"a":NaN}'):
        try:
            spans(invalid, 0, deadline)
        except (ValueError, json.JSONDecodeError):
            continue
        raise AssertionError("invalid fixture accepted")
    return {"status": "MANUAL_UTF8_ESCAPE_NUMERIC_WHITESPACE_SPANS_PASS",
            "positive_value_spans": 5, "nested_value_spans": 1,
            "nested_literal_unicode_container_bytes": 10,
            "nested_literal_unicode_residual_bytes": 6, "invalid_rejected": 3}


def main():
    assert len(sys.argv) == 3
    deadline = time.monotonic()+15
    fixture_result = fixtures(deadline)
    path, output = Path(sys.argv[1]), Path(sys.argv[2])
    assert path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_BYTES
    assert not output.exists() and output.parent.is_dir()
    with path.open("rb") as f:
        raw = f.read(MAX_BYTES+1)
    assert len(raw) == REPORT_BYTES <= MAX_BYTES
    assert hashlib.sha256(raw).hexdigest().upper() == REPORT_SHA
    text = raw.decode("utf-8", errors="strict")
    top, end = spans(text, 0, deadline)
    assert not text[end:].strip()
    evidence = [v for v in top if v[0] == "evidence"]
    assert len(evidence) == 1 and type(evidence[0][3]) is dict
    children, child_end = spans(text, evidence[0][1], deadline)
    assert child_end == evidence[0][2]
    top_rows, evidence_rows = measured(text, top), measured(text, children)
    evidence_value_bytes = len(text[evidence[0][1]:evidence[0][2]].encode("utf-8"))
    for rows in (top_rows, evidence_rows):
        for row in rows:
            part = raw[row["start_byte"]:row["end_byte_exclusive"]]
            assert len(part) == row["value_utf8_bytes"]
            assert hashlib.sha256(part).hexdigest().upper() == row["raw_value_sha256"]
    declared = {k: v for k, _, _, v in top}
    assert type(declared["input_bytes"]) is int
    assert re.fullmatch(r"[a-fA-F0-9]{64}", declared["input_sha256"])
    assert time.monotonic() < deadline
    report = {"status": "EXACT_ACCEPTED_10K_RAW_JSON_VALUE_SPAN_ACCOUNTING",
              "report_bytes": len(raw), "report_sha256": REPORT_SHA,
              "declared_source_input_bytes": declared["input_bytes"],
              "declared_source_input_sha256": declared["input_sha256"],
              "source_input_file_independently_read": False,
              "top_values": top_rows, "evidence_child_values": evidence_rows,
              "top_non_value_bytes": len(raw)-sum(r["value_utf8_bytes"] for r in top_rows),
              "evidence_value_utf8_bytes": evidence_value_bytes,
              "evidence_non_value_bytes": evidence_value_bytes-sum(r["value_utf8_bytes"] for r in evidence_rows),
              "manual_fixtures": fixture_result,
              "limits": ["Value source slices, not parsed-value reserialization or allocation/RAM measurements.",
                         "Nested child accounting overlaps the top evidence value; do not add levels.",
                         "Fixed accepted10k report only; no product/schema/cap change or90kcounterfactual outcome."]}
    assert len(json.dumps(report).encode()) < 64*1024
    with output.open("x", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
