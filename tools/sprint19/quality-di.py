"""Diagnostic-only BPMNDI label projection preserving exact original XML bytes.

Not product import or BPMN execution. Successful projection requires subsequent
unchanged strict parser admission. No unsupported behavior is repaired or dropped.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import xml.parsers.expat as expat

MODEL = 'http://www.omg.org/spec/BPMN/20100524/MODEL'
BPMNDI = 'http://www.omg.org/spec/BPMN/20100524/DI'
DC = 'http://www.omg.org/spec/DD/20100524/DC'
MAX_BYTES = 1048576
MAX_ELEMENTS = 25000
MAX_DEPTH = 16
MAX_COORDINATE = 1000000
NODE_KINDS = {'startEvent': 'start', 'endEvent': 'end', 'task': 'task',
              'exclusiveGateway': 'exclusive_gateway', 'parallelGateway': 'parallel_gateway'}


class ProjectionRefused(ValueError):
    def __init__(self, category, offset=None):
        self.category = category
        self.offset = offset
        super().__init__(category)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def qname(name):
    parts = name.rsplit('}', 1)
    return tuple(parts) if len(parts) == 2 else ('', name)


def tag_end(source, start):
    """Only locate the end of a parser-validated tag in the unchanged source."""
    quote = None
    for index in range(start, len(source)):
        character = source[index]
        if quote is not None:
            if character == quote:
                quote = None
        elif character in (ord('"'), ord("'")):
            quote = character
        elif character == ord('>'):
            return index + 1
    raise ProjectionRefused('unterminated_source_tag', start)


def project(source):
    original_hash = sha(source)
    if len(source) > MAX_BYTES:
        raise ProjectionRefused('input_byte_limit')
    try:
        source.decode('utf-8')
    except UnicodeDecodeError as error:
        raise ProjectionRefused('UTF8_required', error.start) from error
    parser = expat.ParserCreate(namespace_separator='}')
    stack = []
    spans = []
    inventory = []
    nodes = []
    flows = []
    process = None
    count = 0
    parent_references = []

    def refuse(category):
        raise ProjectionRefused(category, parser.CurrentByteIndex)

    def start(name, attributes):
        nonlocal count, process
        namespace, local = qname(name)
        count += 1
        if count > MAX_ELEMENTS or len(stack) >= MAX_DEPTH:
            refuse('XML_complexity_limit')
        position = parser.CurrentByteIndex
        finish = tag_end(source, position)
        empty = source[position:finish].rstrip().endswith(b'/>')
        parent = stack[-1] if stack else None
        element = {'namespace': namespace, 'local': local, 'attributes': dict(attributes),
                   'start': position, 'start_tag_end': finish, 'empty': empty,
                   'label_owner': None, 'label_bounds': None, 'bounds_count': 0}
        if not stack and (namespace, local) != (MODEL, 'definitions'):
            refuse('BPMN_definitions_namespace_required')
        if (namespace, local) == (MODEL, 'standardLoopCharacteristics'):
            refuse('quality_unsupported_standard_loop_before_both_converters')
        if local == 'BPMNLabel':
            if namespace != BPMNDI:
                refuse('wrong_label_namespace')
            if parent is None or parent['local'] not in {'BPMNShape', 'BPMNEdge'}:
                refuse('bad_label_parent')
            if parent['namespace'] != BPMNDI:
                refuse('bad_label_parent_namespace')
            if set(attributes) - {'id'}:
                refuse('unknown_label_attribute')
            association = {'namespace': parent['namespace'], 'local_name': parent['local'],
                           'id': parent['attributes'].get('id'),
                           'bpmnElement': parent['attributes'].get('bpmnElement'),
                           'direct': True}
            if not association['bpmnElement']:
                refuse('label_parent_missing_reference')
            element['label_owner'] = association
            parent_references.append(association)
        elif parent is not None and parent['label_owner'] is not None:
            if local == 'Bounds' and namespace != DC:
                refuse('wrong_bounds_namespace')
            if (namespace, local) != (DC, 'Bounds'):
                if namespace == MODEL:
                    refuse('behavior_child_in_annotation')
                refuse('unknown_annotation_child')
            parent['bounds_count'] += 1
            if parent['bounds_count'] > 1:
                refuse('multiple_label_bounds')
            if set(attributes) - {'x', 'y', 'width', 'height'}:
                refuse('unknown_bounds_attribute')
            if set(attributes) != {'x', 'y', 'width', 'height'}:
                refuse('missing_bounds_attribute')
            bounds = {}
            for key in ('x', 'y', 'width', 'height'):
                try:
                    value = float(attributes[key])
                except (ValueError, OverflowError) as error:
                    raise ProjectionRefused('invalid_label_bound_number', position) from error
                if not math.isfinite(value):
                    refuse('nonfinite_label_bound')
                if re.fullmatch(r'[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?',
                                attributes[key]) is None:
                    refuse('invalid_label_bound_number')
                if abs(value) > MAX_COORDINATE:
                    refuse('label_bound_outside_limit')
                if key in {'width', 'height'} and value < 0:
                    refuse('negative_label_dimension')
                bounds[key] = value
            parent['label_bounds'] = bounds
            element['inside_label_bounds'] = True
        elif parent is not None and parent.get('inside_label_bounds'):
            refuse('nested_bounds_content')
        if (namespace, local) == (MODEL, 'process'):
            if process is not None:
                refuse('multiple_processes')
            process = {'id': attributes.get('id'), 'isExecutable': attributes.get('isExecutable', 'false') == 'true'}
        if parent is not None and (parent['namespace'], parent['local']) == (MODEL, 'process'):
            if namespace == MODEL and local in NODE_KINDS:
                nodes.append({'id': attributes.get('id'), 'kind': NODE_KINDS[local],
                              'label': attributes.get('name', '')})
            elif (namespace, local) == (MODEL, 'sequenceFlow'):
                flows.append({'id': attributes.get('id'), 'source': attributes.get('sourceRef'),
                              'target': attributes.get('targetRef'), 'label': attributes.get('name', '')})
        inventory.append({'namespace': namespace, 'local_name': local,
                          'attributes': dict(attributes), 'byte_start': position,
                          'start_tag_sha256': sha(source[position:finish])})
        stack.append(element)

    def end(name):
        if not stack:
            refuse('XML_stack')
        element = stack.pop()
        if qname(name) != (element['namespace'], element['local']):
            refuse('XML_element_mismatch')
        if element['label_owner'] is not None:
            finish = (element['start_tag_end'] if element['empty']
                      else tag_end(source, parser.CurrentByteIndex))
            raw = source[element['start']:finish]
            spans.append({'byte_start': element['start'], 'byte_length': len(raw),
                          'subtree_sha256': sha(raw), 'raw_utf8': raw.decode('utf-8'),
                          'parent': element['label_owner'], 'label_namespace': BPMNDI,
                          'bounds': element['label_bounds']})

    def characters(value):
        if value.strip() and any(element['label_owner'] is not None or
                                 element.get('inside_label_bounds') for element in stack):
            refuse('nonwhitespace_annotation_text')

    def forbidden_dtd(*unused):
        refuse('DTD_forbidden_no_external_access')

    def declaration(version, encoding, standalone):
        if version != '1.0' or encoding is not None and encoding.lower().replace('-', '') != 'utf8':
            refuse('XML10_UTF8_required')

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.CharacterDataHandler = characters
    parser.StartDoctypeDeclHandler = forbidden_dtd
    parser.EntityDeclHandler = forbidden_dtd
    parser.ExternalEntityRefHandler = forbidden_dtd
    parser.ProcessingInstructionHandler = lambda *unused: refuse('XML_PI_unsupported')
    parser.StartCdataSectionHandler = lambda: refuse('XML_CDATA_unsupported')
    parser.XmlDeclHandler = declaration
    try:
        parser.Parse(source, True)
    except ProjectionRefused:
        raise
    except expat.ExpatError as error:
        raise ProjectionRefused('malformed_XML_or_namespace', parser.ErrorByteIndex) from error
    if process is None:
        raise ProjectionRefused('process_missing')
    node_ids = [node['id'] for node in nodes]
    flow_ids = [flow['id'] for flow in flows]
    identifiers = [process['id'], *node_ids, *flow_ids]
    if any(not isinstance(identity, str) or not identity for identity in identifiers) or len(set(identifiers)) != len(identifiers):
        raise ProjectionRefused('duplicate_or_missing_semantic_id')
    if any(flow['source'] not in node_ids or flow['target'] not in node_ids for flow in flows):
        raise ProjectionRefused('broken_flow_reference')
    for parent in parent_references:
        allowed = node_ids if parent['local_name'] == 'BPMNShape' else flow_ids
        if parent['bpmnElement'] not in allowed:
            raise ProjectionRefused('label_parent_broken_reference')
    spans.sort(key=lambda span: span['byte_start'])
    pieces = []
    cursor = 0
    for span in spans:
        beginning = span['byte_start']
        finish = beginning + span['byte_length']
        if beginning < cursor:
            raise ProjectionRefused('overlapping_label_spans')
        pieces.append(source[cursor:beginning])
        cursor = finish
    pieces.append(source[cursor:])
    projected = b''.join(pieces)
    report = {'schema_version': 1, 'projection_status': 'projected',
              'original_sha256': original_hash, 'original_bytes': len(source),
              'projected_sha256': sha(projected), 'projected_bytes': len(projected),
              'removed_spans': spans, 'raw_construct_inventory': inventory,
              'semantic_map': {'process': process, 'nodes': nodes, 'flows': flows},
              'strict_projected_reparse_required': True,
              'original_product_import_not_claimed': True,
              'reference_must_receive_original_xml': True,
              'not_metric_or_acceptance': True}
    return projected, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.report.exists():
        raise ValueError('fresh_output_and_report_required')
    if not args.input.is_file() or args.input.is_symlink() or args.input.stat().st_size > MAX_BYTES:
        raise ValueError('input_type_or_byte_limit')
    source = args.input.read_bytes()
    try:
        projected, report = project(source)
    except ProjectionRefused as error:
        report = {'schema_version': 1, 'projection_status': 'refused',
                  'category': error.category, 'byte_offset': error.offset,
                  'original_sha256': sha(source), 'original_bytes': len(source),
                  'projected_sha256': None, 'no_partial_projection': True,
                  'not_metric_or_acceptance': True}
        with args.report.open('x', encoding='utf-8') as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2, allow_nan=False)
        raise SystemExit(2)
    with args.output.open('xb') as stream:
        stream.write(projected)
    with args.report.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2, allow_nan=False)


if __name__ == '__main__':
    main()
