"""Bounded same-PG18 logical row fingerprints; never prints private fingerprints."""
import argparse
import copy
import hashlib
import json
import re
from pathlib import Path

ENCODING = 'PG18-jsonb_send-to_jsonb-row-sha256-v1'
TABLES = {'pi_kv', 'pi_projects', 'pi_records', 'pi_migration_v2', 'pi_schema_migrations'}


def need(value, reason):
    if not value:
        raise ValueError(reason)


def unique(pairs):
    out = {}
    for key, value in pairs:
        need(key not in out, 'duplicate_json_key')
        out[key] = value
    return out


def load(path):
    need(not path.is_symlink(), 'snapshot_symlink')
    with path.open('rb') as stream:
        raw = stream.read(2*1024*1024+1)
    need(len(raw) <= 2*1024*1024, 'snapshot_bound')
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda _: need(False, 'nonfinite_json'))


def typed_equal(a, b):
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(typed_equal(v, b[k]) for k, v in a.items())
    if isinstance(a, list):
        return len(a) == len(b) and all(typed_equal(x, y) for x, y in zip(a, b))
    return a == b


def key(value):
    need(type(value) is list and 0 < len(value) <= 3, 'row_key_shape')
    need(all(type(v) in (str, int) for v in value), 'row_key_type')
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def validate(value):
    need(type(value) is dict and set(value) == {'schema_version', 'encoding', 'tables', 'sequences'}, 'snapshot_fields')
    need(type(value['schema_version']) is int and value['schema_version'] == 1, 'snapshot_version')
    need(value['encoding'] == ENCODING, 'snapshot_encoding')
    need(type(value['tables']) is list and len(value['tables']) == 5, 'table_count')
    seen = set()
    for table in value['tables']:
        need(type(table) is dict and set(table) == {'schema', 'name', 'columns', 'owner', 'rls', 'force_rls', 'constraints', 'indexes', 'rows'}, 'table_fields')
        need(table['schema'] == 'public' and table['name'] in TABLES and table['name'] not in seen, 'table_inventory')
        seen.add(table['name'])
        need(type(table['owner']) is str and type(table['rls']) is bool and type(table['force_rls']) is bool, 'table_metadata_type')
        need(type(table['columns']) is list and 0 < len(table['columns']) <= 64, 'column_bound')
        need(type(table['constraints']) is list and type(table['indexes']) is list, 'schema_metadata')
        rows = table['rows']
        need(type(rows) is list and len(rows) <= 10000, 'row_bound')
        keys = set()
        for row in rows:
            need(type(row) is dict and set(row) == {'key', 'version', 'encoded_bytes', 'sha256'}, 'row_fields')
            identity = key(row['key'])
            need(identity not in keys, 'duplicate_row_key')
            keys.add(identity)
            need(row['version'] is None or type(row['version']) is int, 'row_version_type')
            need(type(row['encoded_bytes']) is int and 0 < row['encoded_bytes'] <= 128*1024*1024, 'row_encoded_bytes')
            need(type(row['sha256']) is str and re.fullmatch('[a-f0-9]{64}', row['sha256']), 'row_digest')
    need(seen == TABLES, 'table_inventory')
    need(type(value['sequences']) is list and len(value['sequences']) == 1, 'sequence_count')
    seq = value['sequences'][0]
    need(type(seq) is dict and set(seq) == {'schema', 'name', 'last_value', 'is_called', 'definition'}, 'sequence_fields')
    need(seq['schema'] == 'public' and seq['name'] == 'pi_resource_sequence', 'sequence_identity')
    need(type(seq['last_value']) is int and type(seq['is_called']) is bool and type(seq['definition']) is dict, 'sequence_types')
    return value


def normalize(value, business_only=False):
    value = copy.deepcopy(validate(value))
    value['tables'].sort(key=lambda t: t['name'])
    for table in value['tables']:
        table['rows'].sort(key=lambda r: key(r['key']))
        table['constraints'].sort(key=lambda r: json.dumps(r, sort_keys=True))
        table['indexes'].sort(key=lambda r: json.dumps(r, sort_keys=True))
    if business_only:
        value['tables'] = [t for t in value['tables'] if t['name'] != 'pi_kv']
    return value


def compare(a, b, business_only=False):
    need(typed_equal(normalize(a, business_only), normalize(b, business_only)), 'logical_snapshot_mismatch')


def controls():
    row = {'key': ['Юникод', 9223372036854775807], 'version': None,
           'encoded_bytes': 37, 'sha256': hashlib.sha256(b'fixture-not-pg-encoding').hexdigest()}
    base = {'schema_version': 1, 'encoding': ENCODING, 'tables': [], 'sequences': [
        {'schema': 'public', 'name': 'pi_resource_sequence', 'last_value': 9223372036854775807,
         'is_called': False, 'definition': {'type': 'bigint', 'cycle': False}}]}
    for name in sorted(TABLES):
        base['tables'].append({'schema': 'public', 'name': name, 'columns': [{'name': 'document', 'default': None}],
                              'owner': 'fixture', 'rls': False, 'force_rls': False, 'constraints': [], 'indexes': [], 'rows': [copy.deepcopy(row)]})
    compare(base, copy.deepcopy(base))
    cases = []
    for label in ('same_count_changed_document', 'changed_key', 'missing_row', 'changed_version', 'changed_sequence', 'duplicate_key', 'bool_integer'):
        other = copy.deepcopy(base)
        if label == 'same_count_changed_document':
            other['tables'][0]['rows'][0]['sha256'] = '0'*64
        elif label == 'changed_key':
            other['tables'][0]['rows'][0]['key'][0] = 'другой ключ'
        elif label == 'missing_row':
            other['tables'][0]['rows'].clear()
        elif label == 'changed_version':
            other['tables'][0]['rows'][0]['version'] = 2
        elif label == 'changed_sequence':
            other['sequences'][0]['last_value'] -= 1
        elif label == 'duplicate_key':
            other['tables'][0]['rows'].append(copy.deepcopy(row))
        else:
            other['sequences'][0]['last_value'] = True
        try:
            compare(base, other)
        except ValueError as error:
            expected = {'duplicate_key': 'duplicate_row_key', 'bool_integer': 'sequence_types'}.get(label, 'logical_snapshot_mismatch')
            need(str(error) == expected, 'negative_control_wrong_reason')
            cases.append(label)
        else:
            raise ValueError('negative_control_accepted')
    return {'status': 'PURE_COMPARATOR_CONTROLS_PASS_NOT_PG_EXECUTION', 'negative_cases': cases,
            'unicode_null_bigint_typed_positive': True}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--before', type=Path)
    ap.add_argument('--after', type=Path)
    ap.add_argument('--business-only', action='store_true')
    ap.add_argument('--controls', action='store_true')
    args = ap.parse_args()
    if args.controls:
        need(args.before is None and args.after is None and not args.business_only, 'control_arguments')
        result = controls()
    else:
        need(args.before is not None and args.after is not None, 'snapshot_arguments')
        a, b = load(args.before), load(args.after)
        compare(a, b, args.business_only)
        result = {'status': 'SAME_PG18_LOGICAL_ROW_FINGERPRINTS_MATCH', 'business_only': args.business_only,
                  'tables': len(a['tables']), 'rows': sum(len(t['rows']) for t in a['tables']),
                  'encoding': ENCODING, 'private_fingerprints_not_disclosed': True}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
