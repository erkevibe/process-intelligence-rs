"""Finite known-bundle positive plus two specific negative checks; no children.

CHECKER ZIP EXISTING_EMPTY_PRIVATE_FIXTURES FRESH_PROOF_JSON. Root executes.
Uses actual verified checker bytes and fixed actual evidence, never a mock.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import time

CHECKER = '151d5f5feb64f3c4cd01700ca8ff72f79fc6941556c673b9a1f4419363977869'
BUNDLE = 'c571d7b3c48d6df58dae8147f2afd94f1897af3b5ced14086ac29727db5c6148'
AUDIT = '2d14be0b5d3c8af4727ce11da1e1190c1c34285947d1c5456795ecb3246ab359'
START = time.monotonic()


def need(ok, why):
    if not ok:
        raise ValueError(why)
    if time.monotonic()-START > 45:
        raise ValueError('control_deadline')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read(path, cap):
    need(path.is_file() and path.stat().st_size <= cap, 'bounded_file')
    with path.open('rb') as f:
        value = f.read(cap+1)
    need(len(value) <= cap, 'file_grew')
    return value


def snapshot(root):
    pending = [root]; result = {}; nodes = 0; total = 0
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                nodes += 1; need(nodes <= 128, 'fixture_node_cap')
                path = Path(entry.path); info = path.lstat()
                need(not path.is_symlink() and not getattr(info,'st_file_attributes',0)&1024, 'fixture_reparse')
                if path.is_dir():
                    pending.append(path)
                else:
                    value = read(path, 2*1024*1024); total += len(value)
                    need(total <= 4*1024*1024, 'fixture_byte_cap')
                    result[path.relative_to(root).as_posix()] = {'bytes':len(value),'sha256':sha(value)}
    return result, total


def reject(fn, expected):
    try:
        fn()
    except ValueError as error:
        need(str(error) == expected, 'specific_rejection')
        return expected
    raise ValueError('unexpected_acceptance')


def main():
    p = argparse.ArgumentParser()
    for name in ('checker','bundle','fixtures','output'):
        p.add_argument(name, type=Path)
    a = p.parse_args()
    checker_bytes = read(a.checker, 65536)
    need(sha(checker_bytes) == CHECKER, 'checker_pin')
    bundle_bytes = read(a.bundle, 1024*1024)
    need(len(bundle_bytes) == 37822 and sha(bundle_bytes) == BUNDLE, 'bundle_pin')
    spec = importlib.util.spec_from_file_location('actual_fixed_bundle_checker', a.checker)
    checker = importlib.util.module_from_spec(spec)
    exec(compile(checker_bytes, str(a.checker), 'exec'), checker.__dict__)
    checker.bounded_path(a.fixtures); checker.bounded_path(a.output.parent)
    need(a.fixtures.is_dir() and not any(a.fixtures.iterdir()) and not a.output.exists(), 'fresh_control_outputs')
    need(not a.output.absolute().is_relative_to(a.fixtures.absolute()), 'proof_outside_fixtures')
    positive = a.fixtures/'positive'; positive.mkdir()
    result = checker.check(a.bundle, positive)
    need(result['status'] == 'FIXED_SAVED_SCALE_BUNDLE_AND_FULL_PUBLIC_AUDIT_PASS'
         and result['public_audit_sha256'] == AUDIT, 'actual_positive_full_audit')
    before, positive_bytes = snapshot(positive)
    need(len(before) == 26 and before['public-audit.json']['sha256'] == AUDIT, 'positive_exact_files')
    corrupted = bytearray(bundle_bytes); corrupted[0] ^= 1
    corrupt_path = a.fixtures/'corrupt.zip'
    with corrupt_path.open('xb') as f:
        f.write(corrupted)
    negative = a.fixtures/'negative-empty'; negative.mkdir()
    corrupt_reason = reject(lambda:checker.check(corrupt_path,negative), 'bundle_sha256')
    need(not any(negative.iterdir()), 'corrupt_refusal_before_write')
    overwrite_reason = reject(lambda:checker.check(a.bundle,positive), 'fresh_empty_output')
    after, _ = snapshot(positive)
    need(before == after, 'positive_bytes_changed_after_refusal')
    all_files, total = snapshot(a.fixtures)
    need(len(all_files) == 27 and sha(read(a.bundle,1024*1024)) == BUNDLE, 'original_bundle_preserved')
    proof = {'status':'FIXED_SCALE_BUNDLE_ONE_POSITIVE_TWO_SPECIFIC_NEGATIVES_PASS',
             'checker_sha256':CHECKER,'bundle_sha256':BUNDLE,'public_audit_sha256':AUDIT,
             'positive_count':1,'specific_negative_count':2,
             'negative_reasons':[corrupt_reason,overwrite_reason],
             'corrupt_output_files':0,'positive_files':26,'positive_bytes':positive_bytes,
             'positive_before_after':before,'positive_bytes_unchanged':True,
             'fixture_files':27,'fixture_bytes':total,'original_bundle_unchanged':True,
             'new_engine_execution':False,'scope':'Known fixed ZIP and reviewed checker, not a generic malicious archive or filesystem-race claim.'}
    need(time.monotonic()-START <= 45, 'control_deadline')
    with a.output.open('x',encoding='utf-8',newline='\n') as f:
        json.dump(proof,f,indent=2); f.write('\n')


if __name__ == '__main__':
    main()
