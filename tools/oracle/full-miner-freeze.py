"""Freeze own finite trusted XES corpus before any upstream mining invocation."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2] / 'fixtures/oracle-splitminer'
root.mkdir(exist_ok=False)
cases = {
    'linear': ['ABC', 'ABC'],
    'exclusive-choice': ['ABD', 'ACD', 'ABD', 'ACD'],
    'parallel-interleavings': ['ABCD', 'ACBD'] * 3,
    'self-loop': ['AAB', 'AB', 'AAAB'],
    'short-loop': ['ABAC', 'AC', 'ABABAC'],
    'rare-noise': ['ABC'] * 9 + ['ADC'],
    'empty-log': [],
    'empty-trace': [''],
}
rows = []
for name, variants in cases.items():
    parts = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<log xmlns="http://www.xes-standard.org/" xes.version="1.0">',
             f'<string key="concept:name" value="splitminer-{name}"/>']
    for trace_index, activities in enumerate(variants):
        parts += ['<trace>', f'<string key="concept:name" value="case-{trace_index}"/>']
        for index, activity in enumerate(activities):
            parts += ['<event>', f'<string key="concept:name" value="{activity}"/>',
                      '<string key="lifecycle:transition" value="complete"/>',
                      f'<date key="time:timestamp" value="2024-01-01T00:00:{index:02d}Z"/>', '</event>']
        parts += ['</trace>']
    parts += ['</log>']
    content = ('\n'.join(parts) + '\n').encode()
    file = name + '.xes'
    (root / file).write_bytes(content)
    rows.append({'id': name, 'file': file, 'sha256': hashlib.sha256(content).hexdigest(),
                 'training_variants': variants, 'trace_count': len(variants),
                 'event_count': sum(map(len, variants)),
                 'manual_input_activities': sorted(set(''.join(variants)))})
manifest = {
    'schema_version': 1,
    'scope': 'Finite genuine upstream SplitMiner observations; no expected general quality or Rust parity claim',
    'core_commit': 'bbf24dfd43e72d6992392465f875a4367cbe792b',
    'parameters': {'percentile_frequency_threshold': .40, 'parallelisms_threshold': .10,
                   'filter_type': 'WTH', 'parallelisms_first': False, 'replace_iors': True,
                   'remove_loop_activities': False, 'structuring_time': 'NONE',
                   'classifier': 'org.deckfour.xes.classification.XEventNameClassifier'},
    'corpus': rows,
    'expected_output_policy': 'Observe outcomes including exceptions and internal safe/DFG fallback; do not substitute another miner or tune this frozen corpus after results',
}
path = root / 'corpus.json'
path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'count': len(rows)}))
