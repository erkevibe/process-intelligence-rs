"""Pure filesystem controls for the API observer, never an HTTP/API test."""
import argparse
import hashlib
import json
import os
import sys
import types
from pathlib import Path

SOURCE_SHA = "9D870DF8B9FF3D74595596A414B6F6D9BB07A97A33149BF891507C7533571448"


def expect_error(call, reason):
    try:
        call()
    except AssertionError as error:
        if str(error) != reason:
            raise
    else:
        raise AssertionError("expected_refusal_missing_" + reason)


def main():
    if sys.flags.optimize:
        raise RuntimeError("optimized_mode_not_supported")
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    raw = args.source.read_bytes()
    assert hashlib.sha256(raw).hexdigest().upper() == SOURCE_SHA, "source_identity"
    assert args.out.is_dir() and not any(args.out.iterdir()), "fresh_control_directory"
    module = types.ModuleType("s24_observer_control_import")
    module.__file__ = str(args.source)
    exec(compile(raw, str(args.source), "exec"), module.__dict__)
    checks = []
    journal = args.out / "prefix.jsonl"
    rows = [{"sequence": 1, "fixture": "first"}, {"sequence": 2, "fixture": "second"}]
    for row in rows:
        module.append_durable(journal, row)
    assert module.same(module.journal_rows(journal), rows), "exact_ordered_durable_prefix"
    prefix = journal.read_bytes()
    checks.append("exact_ordered_prefix_fsync_returned")
    with journal.open("ab") as stream:
        stream.write(b'{"sequence":3')
        stream.flush()
        os.fsync(stream.fileno())
    assert journal.read_bytes().startswith(prefix), "previous_prefix_changed"
    expect_error(lambda: module.journal_rows(journal), "journal_partial_or_oversize")
    checks.append("simulated_interrupted_tail_refused_prefix_retained")
    duplicate = args.out / "duplicate.jsonl"
    with duplicate.open("xb") as stream:
        stream.write(b'{"id":1,"id":2}\n')
        stream.flush()
        os.fsync(stream.fileno())
    expect_error(lambda: module.journal_rows(duplicate), "journal_duplicate_key")
    checks.append("duplicate_key_refused")
    failed = args.out / "failed-assertion"
    failed.mkdir()
    probe = module.Probe(None, failed)
    probe.check("synthetic-pass", True)
    expect_error(lambda: probe.check("synthetic-fail", False), "synthetic-fail")
    expected = [{"sequence": 1, "name": "synthetic-pass", "outcome": "passed"},
                {"sequence": 2, "name": "synthetic-fail", "outcome": "failed"}]
    assert module.same(module.journal_rows(failed / "checks.jsonl"), expected), "failed_assertion_not_durable"
    expect_error(probe.reconcile, "check_journal_reconciliation")
    assert not (failed / "proof.json").exists(), "false_full_pass"
    checks.append("failed_assertion_durable_and_not_reconciled_as_pass")
    assert not module.same({"sequence": True}, {"sequence": 1}), "bool_int_alias"
    checks.append("typed_boolean_integer_difference")
    proof = {"status": "PURE_DURABLE_JOURNAL_CONTROLS_PASS", "source_sha256": SOURCE_SHA,
             "checks": checks, "http_requests": 0, "product_or_database_processes": 0,
             "limits": "fsync API returned; simulated tail only, no physical power-loss guarantee"}
    with (args.out / "control-proof.json").open("xb") as stream:
        stream.write(json.dumps(proof, sort_keys=True).encode())
        stream.flush()
        os.fsync(stream.fileno())
    print(json.dumps(proof, sort_keys=True))


if __name__ == "__main__":
    main()
