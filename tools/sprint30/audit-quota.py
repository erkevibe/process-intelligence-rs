#!/usr/bin/env python3
"""Independent structural_bytes_v1 calculation from exported persisted records."""
import json
import math
from pathlib import Path
import sys

KINDS = {'log_state','log_data','log_source','log_analysis','model','conversion','quality','discovery'}


def cost(value):
    if value is None or isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        assert not isinstance(value, float) or math.isfinite(value), 'nonfinite numeric value'
        return 32
    if isinstance(value, str):
        return len(value.encode('utf-8'))
    if isinstance(value, list):
        return 7 + 4*len(value) + sum(map(cost, value))
    if isinstance(value, dict):
        return 7 + 8*len(value) + sum(len(k.encode('utf-8')) + cost(v) for k,v in value.items())
    raise AssertionError('unsupported JSON value')


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, 'duplicate JSON key'
        result[key] = value
    return result


def verify(value):
    assert set(value) == {'schema_version','metric','header_reserve','snapshots'}
    assert type(value['schema_version']) is int and value['schema_version'] == 1 and value['metric'] == 'structural_bytes_v1'
    assert type(value['header_reserve']) is int and value['header_reserve'] == 268369920
    assert isinstance(value['snapshots'],list)
    results = []
    names = set()
    for snapshot in value['snapshots']:
        assert set(snapshot) == {'name','payload_used','records'}
        assert isinstance(snapshot['name'],str) and snapshot['name'] and snapshot['name'] not in names
        names.add(snapshot['name'])
        assert type(snapshot['payload_used']) is int and 0 <= snapshot['payload_used'] <= 2**63-1
        assert isinstance(snapshot['records'],list)
        keys = set()
        used = 0
        for record in snapshot['records']:
            assert set(record) == {'kind','id','document'}
            kind, rid = record['kind'], record['id']
            assert kind in KINDS and isinstance(rid,str) and rid
            assert (kind,rid) not in keys
            keys.add((kind,rid))
            used += 32+len(kind.encode())+len(rid.encode())+cost(record['document'])
        assert used == snapshot['payload_used'], snapshot['name']
        results.append(dict(snapshot=snapshot['name'], records=len(keys), payload_used=used))
    assert results
    return dict(status='S30_INDEPENDENT_QUOTA_ACCOUNTING_PASS',snapshots=results)


def main():
    assert cost({'я':[None,True,'💡',1]}) == 76
    path = Path(sys.argv[1])
    with path.open('rb') as source:
        raw = source.read(32*1024*1024+1)
    assert len(raw) <= 32*1024*1024
    value = json.loads(raw.decode('utf-8-sig'), object_pairs_hook=no_duplicates,
                       parse_constant=lambda _: (_ for _ in ()).throw(AssertionError('nonfinite JSON')))
    print(json.dumps(verify(value),ensure_ascii=False,sort_keys=True))


if __name__ == '__main__':
    main()
