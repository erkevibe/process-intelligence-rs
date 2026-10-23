"""Independent finite codec/semantic counterfactuals; Root alone executes.

Uses Python zlib raw DEFLATE + manually assembled canonical gzip framing,
separate from the Rust product codec. Fixtures are not product conversions.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import time
import zlib

CODEC = "a"*64


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def load_module(path, expected, name):
    raw = Path(path).read_bytes()
    assert len(raw) < 128*1024 and sha(raw).upper() == expected.upper()
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    p = argparse.ArgumentParser()
    p.add_argument("auditor", type=Path); p.add_argument("auditor_sha")
    p.add_argument("oracle", type=Path); p.add_argument("fixtures", type=Path)
    p.add_argument("output", type=Path)
    a = p.parse_args(); start = time.monotonic()
    assert not a.output.exists() and a.output.parent.is_dir()
    checker = load_module(a.auditor, a.auditor_sha, "independent_s23_compact_checker")
    old = checker.oracle(a.oracle)
    result, labels = [], set()

    def gzip_bytes(raw):
        compressor = zlib.compressobj(level=6, wbits=-15)
        body = compressor.compress(raw)+compressor.flush()
        return checker.HEADER+body+struct.pack("<II", zlib.crc32(raw), len(raw) & 0xffffffff)

    def envelope(raw, compressed=None):
        return {"schema_version": 2, "report_profile": checker.PROFILE, "inner_schema_version": 1,
                "codec_sha256": CODEC, "decoded_bytes": len(raw), "decoded_sha256": sha(raw),
                "data_hex": (gzip_bytes(raw) if compressed is None else compressed).hex()}

    def wire(value):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()

    def check(label, accepted, action):
        assert label not in labels and len(result) < 100 and time.monotonic()-start < 90
        labels.add(label)
        try:
            action()
        except (ValueError, UnicodeError, RecursionError, zlib.error) as error:
            assert not accepted, (label, type(error).__name__, str(error))
            result.append({"id": label, "expected": "rejected", "observed": "rejected",
                           "exception_type": type(error).__name__, "reason": str(error)[:160]})
        else:
            assert accepted, label+" unexpectedly accepted"
            result.append({"id": label, "expected": "accepted", "observed": "accepted"})

    inner = {"schema_version": 1, "evidence": {"unicode": "é☃", "escaped": "quote\"\\",
             "null": None, "empty": "", "ordered": ["start", "complete", "start"], "nanos": "000000001"}}
    raw = wire(inner); good = envelope(raw)
    def decode(outer):
        return checker.decode_report(wire(outer), CODEC, allow_legacy=False)
    check("manual_unicode_null_order_full_inner", True,
          lambda: checker.need(checker.typed_equal(decode(good)[0], inner), "manual_full_inner"))
    check("legacy_schema1_read", True,
          lambda: checker.need(checker.typed_equal(checker.decode_report(raw)[0], inner), "legacy_full_inner"))
    check("compact_required_rejects_legacy", False,
          lambda: checker.decode_report(raw, CODEC, allow_legacy=False))
    changes = [
        ("unknown_outer_field", {**good, "extra": 0}),
        ("missing_outer_field", {k: v for k, v in good.items() if k != "decoded_sha256"}),
        ("schema_bool", {**good, "schema_version": True}),
        ("schema_unknown", {**good, "schema_version": 3}),
        ("profile_unknown", {**good, "report_profile": "future"}),
        ("outer_inner_schema_bool", {**good, "inner_schema_version": True}),
        ("inner_schema_unknown", {**good, "inner_schema_version": 2}),
        ("codec_hash_wrong", {**good, "codec_sha256": "b"*64}),
        ("codec_hash_uppercase", {**good, "codec_sha256": "A"*64}),
        ("decoded_hash_wrong", {**good, "decoded_sha256": "0"*64}),
        ("decoded_size_bool", {**good, "decoded_bytes": True}),
        ("decoded_size_negative", {**good, "decoded_bytes": -1}),
        ("decoded_size_zero", {**good, "decoded_bytes": 0}),
        ("decoded_size_smaller", {**good, "decoded_bytes": len(raw)-1}),
        ("decoded_size_larger", {**good, "decoded_bytes": len(raw)+1}),
        ("decoded_size_over_cap", {**good, "decoded_bytes": checker.MAX_DECODED+1}),
        ("hex_odd", {**good, "data_hex": good["data_hex"][:-1]}),
        ("hex_nonhex", {**good, "data_hex": "zz"+good["data_hex"][2:]}),
        ("hex_whitespace", {**good, "data_hex": "  "+good["data_hex"]}),
        ("hex_uppercase", {**good, "data_hex": good["data_hex"].upper()}),
        ("hex_empty", {**good, "data_hex": ""}),
    ]
    for label, changed in changes:
        check(label, False, lambda value=changed: decode(value))
    compressed = bytes.fromhex(good["data_hex"])
    for label, offset in (("gzip_crc", -8), ("gzip_isize", -4), ("gzip_magic", 0),
                          ("gzip_flags", 3), ("gzip_mtime", 4), ("gzip_xfl", 8), ("gzip_os", 9)):
        changed = bytearray(compressed); changed[offset] ^= 1
        check(label, False, lambda value=bytes(changed): decode(envelope(raw, value)))
    for label, data in (("gzip_truncated", compressed[:-1]), ("gzip_trailing_zero", compressed+b"\0"),
                        ("gzip_trailing_lf", compressed+b"\n"), ("gzip_concatenated", compressed+compressed)):
        check(label, False, lambda value=data: decode(envelope(raw, value)))
    for label, bad in (("inner_invalid_utf8", b'{"schema_version":1,"v":"\xff"}'),
                       ("inner_trailing_garbage", raw+b"x"), ("inner_malformed", b'{"schema_version":1,'),
                       ("inner_duplicate_schema", b'{"schema_version":1,"schema_version":1}'),
                       ("inner_nested_duplicate", b'{"schema_version":1,"e":{"v":0,"v":1}}'),
                       ("inner_schema_bool", b'{"schema_version":true}'),
                       ("inner_schema2", b'{"schema_version":2}'), ("inner_scalar", b'1'),
                       ("inner_overflow_float", b'{"schema_version":1,"v":1e999}')):
        check(label, False, lambda value=bad: decode(envelope(value)))
    duplicated_outer = wire(good)[:-1]+b',"schema_version":2}'
    check("outer_duplicate_key", False, lambda: checker.decode_report(duplicated_outer, CODEC, False))
    check("stored_byte_cap", False,
          lambda: checker.decode_report(b" "*(checker.MAX_STORED+1), CODEC, False))

    # Actual 64MiB boundary, then a highly-compressible 64MiB+1 stream which lies
    # about the declared size. No large fixture is written to disk.
    prefix, suffix = b'{"schema_version":1,"padding":"', b'"}'
    padding = checker.MAX_DECODED-len(prefix)-len(suffix)
    at_cap = prefix+b"a"*padding+suffix
    cap_outer = envelope(at_cap)
    check("decoded_exact64MiB", True, lambda: decode(cap_outer))
    over = prefix+b"a"*(padding+1)+suffix
    bomb = envelope(over); bomb["decoded_bytes"] = checker.MAX_DECODED
    check("actual_expansion64MiB_plus1", False, lambda: decode(bomb))
    del at_cap, over, cap_outer, bomb

    # Semantically forged reports use valid CRC, correct decoded size/hash and
    # a coherent outer envelope. Only direct source/payload/manual checking can
    # reject them; framing checks alone are deliberately insufficient.
    corpus_raw = checker.read(a.fixtures/"corpus.json", 512*1024)
    assert sha(corpus_raw) == checker.CORPUS_SHA
    corpus = checker.loads(corpus_raw)
    def fixture(name):
        entries = [e for e in corpus["files"] if e["file"] == name]
        assert len(entries) == 1
        data = checker.read(a.fixtures/name, checker.MAX_FILE)
        assert len(data) == entries[0]["bytes"] and sha(data) == entries[0]["sha256"]
        return data
    source, payload = fixture("flat-unicode.xes"), fixture("flat-unicode.csv")
    manual = checker.loads(fixture("flat-unicode.manual-core.json"))
    declarations = {"source": old.declarations(source, "xes"), "target": old.declarations(payload, "csv"), "metadata_loss_count": 0}
    e = {"profile": "flat-xes-rfc4180-four-columns-v1", "reason": "lossless_core",
         "source_core": copy.deepcopy(manual), "target_core": copy.deepcopy(manual),
         "metadata_loss_count": 0, "losses": [], "trace_count": 1, "event_count": 2,
         "format_declarations": declarations,
         "normalizations": [{"kind": "format_declarations", **declarations}],
         "source_parser_identities": [{"id": "case-0", "name": manual["traces"][0]["name"], "ordinals": [0, 1]}],
         "source_parser_warnings": checker.XES_WARNINGS, "target_parser_warnings": [],
         "actual_inverse_conversion_not_claimed": True}
    logical = {"schema_version": 1, "method_sha256": checker.METHOD, "from": "xes", "to": "csv",
               "allow_metadata_loss": False, "input_sha256": sha(source), "input_bytes": len(source),
               "sources": {}, "target_sha256": sha(payload), "target_bytes": len(payload),
               "payload_file": "payload.csv", "not_general_format_support": True,
               "status": "converted", "reason": "lossless_core", "evidence": e}
    def semantic(value, target=payload):
        decoded, _ = decode(envelope(wire(value)))
        checker.common(decoded, source, target, "xes", "csv", False)
        checker.semantics(old, decoded, source, target, "xes", "csv", manual)
    check("manual_direct_source_payload_full_evidence", True, lambda: semantic(logical))
    def mutated(label, action):
        value = copy.deepcopy(logical); action(value["evidence"])
        check(label, False, lambda: semantic(value))
    mutated("rehash_claimed_activity", lambda v: v["source_core"]["traces"][0]["events"][0].update(activity="forged"))
    mutated("rehash_claimed_timestamp", lambda v: v["target_core"]["traces"][0]["events"][0].update(timestamp=None))
    mutated("rehash_claimed_event_drop", lambda v: v["target_core"]["traces"][0]["events"].pop())
    mutated("rehash_claimed_event_order", lambda v: v["target_core"]["traces"][0]["events"].reverse())
    mutated("rehash_ordinal_bool", lambda v: v["source_parser_identities"][0].update(ordinals=[False, 1]))
    mutated("rehash_trace_count_bool", lambda v: v.update(trace_count=True))
    mutated("rehash_warning_removed", lambda v: v.update(source_parser_warnings=[]))
    mutated("rehash_normalization_removed", lambda v: v.update(normalizations=[]))
    mutated("rehash_loss_claim", lambda v: v.update(metadata_loss_count=1))
    mutated("rehash_reason", lambda v: v.update(reason="empty_log"))
    mutated("rehash_profile", lambda v: v.update(profile="unknown"))
    mutated("rehash_format_count_bool", lambda v: v["format_declarations"].update(metadata_loss_count=False))
    mutated("rehash_format_present_int", lambda v: v["format_declarations"]["source"]["xes.version"].update(present=1))
    mutated("rehash_format_normalization_count_bool", lambda v: v["normalizations"][0].update(metadata_loss_count=False))
    changed_payload = payload.replace(b"A", b"forged", 1)
    # The common target identity is coherently updated while original source and
    # manual oracle remain frozen, so this cannot fail merely on a stale hash.
    target_forgery = copy.deepcopy(logical)
    target_forgery.update(target_sha256=sha(changed_payload), target_bytes=len(changed_payload))
    check("rehash_actual_target_field", False, lambda: semantic(target_forgery, changed_payload))
    assert time.monotonic()-start < 90
    proof = {"status": "INDEPENDENT_COMPACT_CODEC_AND_REHASHED_SEMANTIC_CONTROLS_PASS",
             "auditor_sha256": a.auditor_sha, "cases": result,
             "accepted": sum(r["observed"] == "accepted" for r in result),
             "rejected": sum(r["observed"] == "rejected" for r in result),
             "limits": ["Synthetic wire fixtures, not product conversion/native success evidence.",
                        "One actual64MiB decode and one64MiB+1 expansion rejection use bounded memory-only fixtures.",
                        "Coherently rehashed semantic forgeries checked against frozen manual source/payload, no product decoder."]}
    with a.output.open("x", encoding="utf-8") as stream:
        json.dump(proof, stream, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
