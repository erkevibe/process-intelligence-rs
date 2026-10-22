"""Frozen eight-row cohort projection only; no converter, miner or metric execution."""
import argparse
import hashlib
import importlib.util
import json
from collections import Counter
from pathlib import Path
import xml.etree.ElementTree as ET

COHORT_SHA = '6dac7a9b69d553590f342ed4b836140678a9f2c072cc806119f0ecc48ace208d'
HINT_SHA = '971157628baf7b4fd7653da2e1dbe5c74dbfc09415f9fb5dafc287e28bc127c0'
DI_SHA = '1a02819cec37c3ebeb9a29aceccc562041d32601f3e16f8e1bbf0f9b8f13c729'
ROOT = Path(__file__).resolve().parents[2]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False).encode('utf-8')


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def read(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024,
            'regular_bounded_input_required')
    return path.read_bytes()


def write(path, data):
    with path.open('xb') as stream:
        stream.write(data)


def module(name, file, expected):
    path = ROOT / 'tools' / 'sprint19' / file
    require(sha(read(path)) == expected, 'projector_source_hash:' + file)
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def reconstruct(raw, report):
    require(report['original_sha256'] == sha(raw) and report['original_bytes'] == len(raw),
            'projection_original_binding')
    result, cursor = [], 0
    for row in report['removed_spans']:
        start, length = row['byte_start'], row['byte_length']
        require(isinstance(start, int) and isinstance(length, int) and length > 0 and
                cursor <= start and start + length <= len(raw), 'projection_span_bounds')
        fragment = raw[start:start + length]
        require(sha(fragment) == row['subtree_sha256'] and
                fragment.decode('utf-8') == row['raw_utf8'], 'projection_span_bytes')
        result.append(raw[cursor:start])
        cursor = start + length
    result.append(raw[cursor:])
    output = b''.join(result)
    require(report['projected_sha256'] == sha(output) and report['projected_bytes'] == len(output),
            'projection_output_binding')
    return output


def verify_traces(raw, source):
    require(b'<!DOCTYPE' not in raw and b'<!ENTITY' not in raw, 'xes_declarations_refused')
    root = ET.fromstring(raw)
    traces = []
    for trace in root:
        if trace.tag.rsplit('}', 1)[-1] != 'trace':
            continue
        sequence = []
        for event in trace:
            if event.tag.rsplit('}', 1)[-1] != 'event':
                continue
            names = [item.attrib.get('value') for item in event
                     if item.attrib.get('key') == 'concept:name']
            require(len(names) == 1 and isinstance(names[0], str), 'xes_activity_name')
            sequence.append(names[0])
        names = [item.attrib.get('value') for item in trace if item.attrib.get('key') == 'concept:name']
        require(len(names) == 1, 'xes_trace_name')
        traces.append({'source_trace_index': len(traces), 'source_trace_name': names[0],
                       'sequence': sequence, 'event_count': len(sequence)})
    require(traces == source['traces'] and len(traces) == source['trace_count'] and
            sum(row['event_count'] for row in traces) == source['event_count'], 'xes_trace_lineage')
    actual = Counter(tuple(row['sequence']) for row in traces)
    frozen = {tuple(row['sequence']): row['frequency'] for row in source['training_log']}
    require(len(frozen) == len(source['training_log']) and actual == frozen and
            source['heldout_log'] is None, 'xes_training_frequencies')


def prepare(corpus_path, output):
    cohort_bytes = read(corpus_path)
    require(sha(cohort_bytes) == COHORT_SHA, 'frozen_cohort_hash')
    corpus = json.loads(cohort_bytes)
    require(len(corpus['cases']) == 8 and len({row['id'] for row in corpus['cases']}) == 8,
            'eight_unique_rows')
    hint = module('quality_schema_hint', 'schema-hint.py', HINT_SHA)
    di = module('quality_di_frozen', 'quality-di.py', DI_SHA)
    output.mkdir()
    (output / 'inputs').mkdir()
    (output / 'projection').mkdir()
    write(output / 'inputs' / 'corpus.json', cohort_bytes)
    rows = []
    for case in corpus['cases']:
        identity = case['id']
        require(identity and all(c.isalnum() or c == '-' for c in identity), 'safe_case_id')
        source = case['source_input']
        xes = read(corpus_path.parent / source['file'])
        require(sha(xes) == source['sha256'].lower() and len(xes) == source['bytes'], 'source_xes_hash')
        verify_traces(xes, source)
        write(output / 'inputs' / (identity + '.xes'), xes)
        row = {'id': identity, 'source_xes_file': identity + '.xes', 'source_xes_sha256': sha(xes),
               'trace_lineage_verified': True, 'source_input': source,
               'carried_actual_outcome': case['carried_actual_outcome']}
        if case['raw_bpmn'] is None:
            row.update(status='carried_algorithm_exception', raw_file=None,
                       exception=case['carried_actual_outcome']['exception'])
            rows.append(row)
            continue
        model = case['raw_bpmn']
        raw = read(corpus_path.parent / model['file'])
        require(sha(raw) == model['sha256'].lower() and len(raw) == model['bytes'], 'original_raw_hash')
        raw_name = identity + '.raw.bpmn'
        write(output / 'inputs' / raw_name, raw)
        row.update(raw_file=raw_name, raw_sha256=sha(raw), raw_bytes=len(raw))
        try:
            intermediate, hint_report = hint.project(raw)
            require(reconstruct(raw, hint_report) == intermediate, 'hint_reconstruction')
            projected, di_report = di.project(intermediate)
            require(reconstruct(intermediate, di_report) == projected, 'di_reconstruction')
            require(hint_report['semantic_map'] == di_report['semantic_map'], 'two_stage_semantic_map')
        except (hint.ProjectionRefused, di.ProjectionRefused) as error:
            row.update(status='raw_compatibility_refused', category=error.category,
                       no_partial_projection=True)
            rows.append(row)
            continue
        row.update(status='projected_pending_strict_prepare')
        for key, name, data in [('hint', identity + '.hint.bpmn', intermediate),
                                ('hint_report', identity + '.hint.json', encoded(hint_report)),
                                ('projected', identity + '.projected.bpmn', projected),
                                ('di_report', identity + '.di.json', encoded(di_report))]:
            write(output / 'projection' / name, data)
            row[key + '_file'] = name
            row[key + '_sha256'] = sha(data)
        rows.append(row)
    bundle = {'schema_version': 1, 'phase': 'cohort_projection_only_no_converter',
              'cohort_sha256': COHORT_SHA, 'sources': {
                  'tools/sprint19/schema-hint.py': HINT_SHA,
                  'tools/sprint19/quality-di.py': DI_SHA,
                  'tools/sprint19/quality-miner-project.py': sha(read(Path(__file__)))},
              'schema_policy_sha256': 'd49c756db26e952d32ae800ac7847ae9692adf27a71d847f30a8d7eb8a58d39d',
              'di_policy_sha256': corpus['DI_addendum_sha256'],
              'cases': rows, 'not_acceptance': True, 'no_metric_or_conversion_executed': True}
    write(output / 'projection.json', encoded(bundle))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cohort', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.cohort, args.output)
