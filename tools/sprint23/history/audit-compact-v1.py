"""Independent bounded schema2 decoder and direct source/payload proof audit.

No converter or product decoder is imported/executed. The pinned pre-S23 manual
auditor independently parses formats and inventories losses/normalizations.
Native invocation/exit/EOF and actual inverse execution remain separate gates.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import time
import zlib

PROFILE = "gzip-hex-report-v1"
MAX_STORED = 4*1024*1024
MAX_DECODED = 64*1024*1024
MAX_FILE = 20*1024*1024
ORACLE_SHA = "C3CF6D5B5B5B0A4067C29175C4857964B81B766A84D1ED5C029AD49ED929BA3A"
CORPUS_SHA = "621dc9106835eb3274659a08f033da4b74ef7cce9a58846e4b01788c866cfe34"
METHOD = "49dc32d1f4219965ea57cc79caa9355974269fab989cc38d09173c8e734e619b"
HEADER = bytes.fromhex("1f8b08000000000000ff")
FIELDS = {"schema_version", "report_profile", "inner_schema_version", "codec_sha256",
          "decoded_bytes", "decoded_sha256", "data_hex"}
XES_WARNINGS = ["Порядок событий — как в XML. Lifecycle start/complete не объединяются.",
                "Совместимость с Apromore ещё не подтверждена legacy oracle."]


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def pairs(values):
    result = {}
    for key, value in values:
        need(key not in result, "duplicate_json_key")
        result[key] = value
    return result


def loads(raw):
    def finite_float(value):
        number = float(value)
        need(math.isfinite(number), "nonfinite_json_float")
        return number
    return json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=pairs,
                      parse_float=finite_float,
                      parse_constant=lambda x: need(False, "nonfinite_json"))


def typed_equal(left, right):
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(typed_equal(v, right[k]) for k, v in left.items())
    if isinstance(left, list):
        return len(left) == len(right) and all(typed_equal(a, b) for a, b in zip(left, right))
    return left == right


def decode_report(raw, expected_codec_sha=None, allow_legacy=True, *, return_raw=False,
                  require_codec_identity=True):
    need(len(raw) <= MAX_STORED, "stored_report_cap")
    outer = loads(raw)
    need(type(outer) is dict and type(outer.get("schema_version")) is int, "outer_schema_type")
    if outer["schema_version"] == 1:
        need(allow_legacy, "compact_required")
        result = (outer, {"stored_schema": 1, "stored_sha256": digest(raw), "stored_bytes": len(raw)})
        return (*result, raw) if return_raw else result
    need(outer["schema_version"] == 2 and set(outer) == FIELDS, "outer_exact_fields")
    need(outer["report_profile"] == PROFILE and type(outer["inner_schema_version"]) is int
         and outer["inner_schema_version"] == 1, "profile_inner_schema")
    for key in ("codec_sha256", "decoded_sha256"):
        need(type(outer[key]) is str and re.fullmatch(r"[a-f0-9]{64}", outer[key]), "lowercase_hash")
    if expected_codec_sha is not None:
        need(type(expected_codec_sha) is str and re.fullmatch(r"[a-fA-F0-9]{64}", expected_codec_sha)
             and outer["codec_sha256"] == expected_codec_sha.lower(), "codec_source_identity")
    else:
        need(not require_codec_identity, "codec_source_identity_required")
    count = outer["decoded_bytes"]
    need(type(count) is int and 0 < count <= MAX_DECODED, "decoded_declared_bound")
    value = outer["data_hex"]
    need(type(value) is str and 0 < len(value) <= MAX_STORED and len(value) % 2 == 0
         and re.fullmatch(r"[a-f0-9]+", value), "strict_lower_even_hex")
    compressed = bytes.fromhex(value)
    need(len(compressed) >= 18 and compressed[:10] == HEADER, "canonical_single_gzip_header")
    decoder = zlib.decompressobj(16+zlib.MAX_WBITS)
    # +1 detects either advertised-size overflow or the global bomb threshold
    # before retaining more than that bounded amount of decompressed output.
    try:
        inner = decoder.decompress(compressed, min(count, MAX_DECODED)+1)
    except zlib.error as error:
        raise ValueError("gzip_crc_or_stream") from error
    need(len(inner) <= count and len(inner) <= MAX_DECODED, "decoded_actual_bound")
    need(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,
         "one_complete_member_no_trailing_concat")
    need(len(inner) == count and digest(inner) == outer["decoded_sha256"], "decoded_size_sha")
    report = loads(inner)
    need(type(report) is dict and type(report.get("schema_version")) is int
         and report["schema_version"] == 1, "decoded_full_inner_schema")
    result = (report, {"stored_schema": 2, "profile": PROFILE, "codec_sha256": outer["codec_sha256"],
                    "stored_sha256": digest(raw), "stored_bytes": len(raw),
                    "decoded_bytes": len(inner), "decoded_sha256": digest(inner),
                    "codec_source_identity_verified": expected_codec_sha is not None})
    return (*result, inner) if return_raw else result


def read(path, cap):
    path = Path(path)
    need(path.is_file() and not path.is_symlink() and path.stat().st_size <= cap, "bounded_regular_file")
    with path.open("rb") as stream:
        raw = stream.read(cap+1)
    need(len(raw) <= cap, "actual_file_cap")
    return raw


def oracle(path):
    need(digest(read(path, 128*1024)).upper() == ORACLE_SHA, "independent_oracle_source_pin")
    spec = importlib.util.spec_from_file_location("approved_pre_s23_manual_auditor", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def provenance(report, root, codec_sha):
    sources = report["sources"]
    need(type(sources) is dict and sources.get("locked_process_mining") == "0.6.2", "locked_parser_provenance")
    allowed = {"Cargo.lock", "examples/pi_convert.rs", "src/conversion/mod.rs", "src/conversion/xml.rs",
               "src/conversion/logs.rs", "src/conversion/net.rs", "src/conversion/compact.rs",
               "src/event_io.rs", "src/csv_io.rs"}
    need(set(sources)-{"locked_process_mining"} <= allowed, "source_keys_allowlist")
    need(allowed-{"src/conversion/compact.rs"} <= set(sources), "complete_legacy_source_provenance")
    if "src/conversion/compact.rs" in sources:
        need(sources["src/conversion/compact.rs"] == codec_sha.lower(), "inner_codec_source_identity")
    for name, expected in sources.items():
        if name == "locked_process_mining":
            continue
        need(type(expected) is str and re.fullmatch(r"[a-f0-9]{64}", expected), "source_hash_type")
        if root is not None:
            need(digest(read(Path(root)/name, 2*1024*1024)) == expected, "source_file_hash")


def common(report, source, payload, from_kind, to_kind, allow, expected_status="converted"):
    fields = {"schema_version", "method_sha256", "from", "to", "allow_metadata_loss", "input_sha256",
              "input_bytes", "sources", "target_sha256", "target_bytes", "payload_file",
              "not_general_format_support", "status", "reason"}
    need(set(report) == fields | ({"evidence"} if expected_status == "converted" else {"details"}), "full_inner_exact_fields")
    need(report["schema_version"] == 1 and report["method_sha256"] == METHOD, "common_method_schema")
    need(report["from"] == from_kind and report["to"] == to_kind and report["status"] == expected_status, "direction_status")
    need(report["allow_metadata_loss"] is allow, "allow_loss_policy")
    need(type(report["input_bytes"]) is int and report["input_bytes"] == len(source)
         and report["input_sha256"] == digest(source), "direct_source_binding")
    need(report["not_general_format_support"] is True, "finite_scope_flag")
    if payload is None:
        need(report["payload_file"] is None and report["target_sha256"] is None
             and report["target_bytes"] is None, "refusal_no_pair")
    else:
        extension = {"csv": "csv", "xes": "xes"}[to_kind]
        need(report["payload_file"] == "payload."+extension and report["target_sha256"] == digest(payload)
             and type(report["target_bytes"]) is int and report["target_bytes"] == len(payload), "direct_payload_binding")


def semantics(old, report, source, payload, source_kind, target_kind, manual=None):
    left, losses = old.core(source, source_kind)
    right, target_losses = old.core(payload, target_kind, strict_output=True)
    need(typed_equal(left, right) and not target_losses, "direct_ordered_source_payload_core")
    if manual is not None:
        need(typed_equal(left, manual), "frozen_manual_core")
    e = report["evidence"]
    need(set(e) == {"profile", "reason", "source_core", "target_core", "metadata_loss_count",
         "losses", "normalizations", "format_declarations", "trace_count", "event_count",
         "source_parser_warnings", "target_parser_warnings", "source_parser_identities",
         "actual_inverse_conversion_not_claimed"}, "full_log_evidence_fields")
    reason = "explicit_metadata_loss" if losses else ("empty_log" if not left["traces"] else "lossless_core")
    need(e["profile"] == "flat-xes-rfc4180-four-columns-v1" and e["reason"] == reason
         and report["reason"] == reason, "direct_profile_reason")
    need(typed_equal(e["source_core"], left) and typed_equal(e["target_core"], right), "claimed_full_core")
    need(type(e["metadata_loss_count"]) is int and e["metadata_loss_count"] == len(losses), "typed_loss_count")
    need(typed_equal(old.canonical_losses(e["losses"]), old.canonical_losses(losses)), "complete_independent_loss_inventory")
    old.loss_locations(e["losses"], source, source_kind)
    declarations = {"source": old.declarations(source, source_kind),
                    "target": old.declarations(payload, target_kind), "metadata_loss_count": 0}
    need(typed_equal(e["format_declarations"], declarations), "typed_format_declarations")
    need(typed_equal([row for row in e["normalizations"] if row.get("kind") == "format_declarations"],
                     [{"kind": "format_declarations", **declarations}]), "typed_format_normalization")
    normalization_rows = old.lexical_normalizations(source, source_kind)
    if source_kind == "csv" and len(declarations["source"]["headers"]) > 4:
        normalization_rows.append({"kind": "csv_extra_columns_omitted",
                                   "columns": declarations["source"]["headers"][4:]})
    normalization_rows.append({"kind": "format_declarations", **declarations})
    need(typed_equal(old.canonical_losses(e["normalizations"]), old.canonical_losses(normalization_rows)),
         "typed_complete_normalization_inventory")
    old.log_report_integrity(e, source, source_kind, payload, target_kind)
    count = sum(len(t["events"]) for t in left["traces"])
    need(type(e["event_count"]) is int and e["event_count"] == count
         and type(e["trace_count"]) is int and e["trace_count"] == len(left["traces"]), "typed_event_trace_counts")
    identities, ordinal = [], 0
    for number, trace in enumerate(left["traces"]):
        n = len(trace["events"])
        identities.append({"id": "case-"+str(number), "name": trace["name"],
                           "ordinals": list(range(n)) if source_kind == "xes" else list(range(ordinal, ordinal+n))})
        ordinal += n
    need(typed_equal(e["source_parser_identities"], identities), "direct_parser_identity_ordinals")
    need(typed_equal(e["source_parser_warnings"], XES_WARNINGS if source_kind == "xes" else [])
         and typed_equal(e["target_parser_warnings"], XES_WARNINGS if target_kind == "xes" else []), "full_parser_warnings")
    need(e["actual_inverse_conversion_not_claimed"] is True, "no_fictional_inverse")
    return left, count


def main():
    p = argparse.ArgumentParser()
    p.add_argument("report", type=Path); p.add_argument("output", type=Path)
    p.add_argument("--source", required=True, type=Path)
    p.add_argument("--payload", type=Path)
    p.add_argument("--oracle", required=True, type=Path)
    p.add_argument("--codec-sha", required=True)
    p.add_argument("--source-root", type=Path)
    p.add_argument("--from", dest="source_kind", choices=("xes", "csv"), required=True)
    p.add_argument("--to", dest="target_kind", choices=("xes", "csv"), required=True)
    p.add_argument("--allow-loss", action="store_true")
    p.add_argument("--require-compact", action="store_true")
    p.add_argument("--inverse-payload", type=Path); p.add_argument("--inverse-report", type=Path)
    p.add_argument("--complexity", choices=("CMP10K", "CMP90K"))
    p.add_argument("--corpus", type=Path); p.add_argument("--case-id")
    args = p.parse_args(); started = time.monotonic()
    need(not args.output.exists() and args.output.parent.is_dir(), "fresh_output")
    need(args.source_kind != args.target_kind, "log_direction")
    old = oracle(args.oracle)
    source = read(args.source, MAX_FILE)
    payload = read(args.payload, MAX_FILE) if args.payload else None
    report, encoding = decode_report(read(args.report, MAX_STORED), args.codec_sha, not args.require_compact)
    expected_status, manual = "converted", None
    if args.case_id:
        need(args.corpus is not None, "frozen_corpus_required")
        raw = read(args.corpus, 512*1024); need(digest(raw) == CORPUS_SHA, "frozen_corpus_sha")
        corpus = loads(raw)
        def frozen_file(name):
            need(type(name) is str and ".." not in Path(name).parts and not Path(name).is_absolute()
                 and ":" not in name and "\\" not in name, "manual_relative")
            entries = [v for v in corpus["files"] if v["file"] == name]
            need(len(entries) == 1, "unique_frozen_file")
            data = read(args.corpus.parent/name, MAX_FILE)
            need(len(data) == entries[0]["bytes"] and digest(data) == entries[0]["sha256"], "frozen_manual_file_pin")
            return data
        cases = [c for c in corpus["cases"] if c["id"] == args.case_id]
        need(len(cases) == 1, "unique_frozen_case")
        case = cases[0]; expected_status = case["expected"]["status"]
        need(case["input_sha256"] == digest(source) and case["from"] == args.source_kind
             and case["to"] == args.target_kind and case["allow_metadata_loss"] is args.allow_loss, "case_identity")
        need(report["reason"] == case["expected"]["reason"], "manual_reason")
        name = case["expected"].get("manual_semantics", {}).get("core_file")
        if name:
            manual = loads(frozen_file(name))
        if expected_status == "converted" and args.target_kind == "csv" and case["expected"].get("direct_target_file"):
            need(payload == frozen_file(case["expected"]["direct_target_file"]), "exact_frozen_manual_csv_bytes")
    common(report, source, payload, args.source_kind, args.target_kind, args.allow_loss, expected_status)
    provenance(report, args.source_root, args.codec_sha)
    core, count = (None, None)
    if expected_status == "converted":
        need(payload is not None, "converted_pair_required")
        core, count = semantics(old, report, source, payload, args.source_kind, args.target_kind, manual)
    else:
        need(payload is None and not args.complexity, "refusal_not_success")
        if expected_status == "loss_refused":
            _, losses = old.core(source, args.source_kind)
            e = report["details"]
            need(typed_equal(old.canonical_losses(e["losses"]), old.canonical_losses(losses)), "refusal_complete_losses")
            old.loss_locations(e["losses"], source, args.source_kind)
            need(type(e["metadata_loss_count"]) is int and e["metadata_loss_count"] == len(losses), "refusal_typed_loss_count")
            expected_normalizations = old.lexical_normalizations(source, args.source_kind)
            if args.source_kind == "csv":
                extra = old.declarations(source, "csv")["headers"][4:]
                if extra:
                    expected_normalizations.append({"kind": "csv_extra_columns_omitted", "columns": extra})
            need(typed_equal(old.canonical_losses(e["normalizations"]), old.canonical_losses(expected_normalizations)), "refusal_complete_normalizations")
            need(typed_equal(e["parser_warnings"], XES_WARNINGS if args.source_kind == "xes" else []), "refusal_parser_warnings")
    if args.complexity:
        n, pin = {"CMP10K": (10000, "feb62e2eba2469264021333c71074a32049dfd049f58ac2a59b2896437aa7793"),
                  "CMP90K": (90000, "cbbd54489e7058054ebb4fd4091759024ea660129e736ef1f7c640c55f55bd8d")}[args.complexity]
        need(args.source_kind == "xes" and digest(source) == pin and count == n, "fixed_complexity_input")
        need(len(core["traces"]) == 1 and core["traces"][0]["name"] == "complexity-case", "manual_complexity_trace")
        for event in core["traces"][0]["events"]:
            need(typed_equal(event, {"activity": "A", "timestamp": "2026-01-01T00:00:00.000000001Z", "lifecycle": None}), "all_manual_complexity_events")
    need(bool(args.inverse_payload) == bool(args.inverse_report), "inverse_pair_arguments")
    inverse_checked = False
    if args.inverse_payload:
        need(payload is not None, "inverse_source_pair")
        restored = read(args.inverse_payload, MAX_FILE)
        inverse, inverse_encoding = decode_report(read(args.inverse_report, MAX_STORED), args.codec_sha)
        common(inverse, payload, restored, args.target_kind, args.source_kind, False)
        provenance(inverse, args.source_root, args.codec_sha)
        returned, _ = semantics(old, inverse, payload, restored, args.target_kind, args.source_kind)
        need(typed_equal(core, returned), "provided_inverse_fieldwise_core")
        inverse_checked = True
    need(time.monotonic()-started < 120, "saved_audit_deadline")
    result = {"status": "INDEPENDENT_COMPACT_REPORT_DIRECT_SOURCE_PAYLOAD_AUDIT_PASS",
              "encoding": encoding, "logical_schema": 1, "from": args.source_kind, "to": args.target_kind,
              "source_sha256": digest(source), "source_bytes": len(source),
              "payload_sha256": digest(payload) if payload is not None else None,
              "payload_bytes": len(payload) if payload is not None else None,
              "logical_status": expected_status, "event_count": count, "frozen_case": args.case_id,
              "manual_complexity": args.complexity, "provided_inverse_pair_checked": inverse_checked,
              "native_invocation_verified": False, "source_provenance_files_checked": args.source_root is not None,
              "limits": ["Direct independent input/payload parsing and full claimed evidence; no product decoder.",
                         "Actual native invocation/exit/fullEOF, including actual inverse, are separate ProcessLogAuditor gates.",
                         "Finite approved profile/manual corpus, no broad R5/enterprise/RAM claim."]}
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
