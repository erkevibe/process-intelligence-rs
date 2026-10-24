"""Decode a compact report to its exact logical JSON bytes; not a semantic proof audit.

Usage: decode-report.py INPUT_REPORT NEW_OUTPUT_JSON [--codec-sha HEX]
Keep audit-compact.py beside this file. The optional SHA binds codec provenance;
without it framing/integrity are checked, but codec source identity is unverified.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import time


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--codec-sha")
    args = parser.parse_args()
    source = Path(__file__).with_name("audit-compact.py")
    if source.is_symlink() or not source.is_file() or source.stat().st_size > 128*1024:
        raise ValueError("decoder_module_bounds")
    spec = importlib.util.spec_from_file_location("independent_compact_decoder", source)
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    raw = audit.read(args.report, audit.MAX_STORED)
    _, metadata, decoded = audit.decode_report(raw, args.codec_sha, allow_legacy=False,
        return_raw=True, require_codec_identity=args.codec_sha is not None)
    audit.need(len(decoded) <= audit.MAX_DECODED and time.monotonic()-started < 30, "decoder_bounds")
    audit.need(args.output.parent.is_dir() and not args.output.parent.is_symlink()
               and not args.output.exists() and not args.output.is_symlink(), "fresh_output")
    with args.output.open("xb") as stream:
        stream.write(decoded)
    print(json.dumps({"status":"EXACT_LOGICAL_REPORT_DECODED", **metadata,
        "semantic_source_payload_audit_performed":False}, sort_keys=True))


if __name__ == "__main__":
    main()
