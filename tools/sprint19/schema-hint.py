"""Narrow diagnostic-only canonical root XSI hint projection; never resolve schemas."""
import argparse
import hashlib
import json
from pathlib import Path
import xml.parsers.expat as expat

MODEL = 'http://www.omg.org/spec/BPMN/20100524/MODEL'
XSI = 'http://www.w3.org/2001/XMLSchema-instance'
CANONICAL = MODEL + ' BPMN20.xsd'
MAX_BYTES = 1048576
NODE_KINDS = {'startEvent': 'start', 'endEvent': 'end', 'task': 'task',
              'exclusiveGateway': 'exclusive_gateway', 'parallelGateway': 'parallel_gateway'}


class ProjectionRefused(ValueError):
    def __init__(self, category, offset=None):
        super().__init__(category)
        self.category, self.offset = category, offset


def sha(data):
    return hashlib.sha256(data).hexdigest()


def qname(name):
    parts = name.rsplit('}', 1)
    return tuple(parts) if len(parts) == 2 else ('', name)


def lexical_attributes(source, start):
    """Read original attribute lexical spans after Expat validates the start tag."""
    index = start + 1
    while index < len(source) and source[index] not in b' \t\r\n/>':
        index += 1
    result = []
    while index < len(source):
        while index < len(source) and source[index] in b' \t\r\n':
            index += 1
        if index >= len(source) or source[index] in b'/>':
            return result
        beginning = index
        while index < len(source) and source[index] not in b' \t\r\n=/>':
            index += 1
        name = source[beginning:index].decode('utf-8')
        while index < len(source) and source[index] in b' \t\r\n':
            index += 1
        if index >= len(source) or source[index] != ord('='):
            raise ProjectionRefused('malformed_XML_or_namespace', index)
        index += 1
        while index < len(source) and source[index] in b' \t\r\n':
            index += 1
        if index >= len(source) or source[index] not in (ord('"'), ord("'")):
            raise ProjectionRefused('malformed_XML_or_namespace', index)
        quote = source[index]
        index += 1
        value_start = index
        while index < len(source) and source[index] != quote:
            index += 1
        if index >= len(source):
            raise ProjectionRefused('malformed_XML_or_namespace', index)
        raw_value = source[value_start:index]
        index += 1
        result.append({'name': name, 'start': beginning, 'end': index,
                       'raw_value': raw_value, 'quote': chr(quote)})
    raise ProjectionRefused('malformed_XML_or_namespace', index)


def project(source):
    if len(source) > MAX_BYTES:
        raise ProjectionRefused('input_byte_limit')
    try:
        source.decode('utf-8')
    except UnicodeDecodeError as error:
        raise ProjectionRefused('UTF8_required', error.start) from error
    parser = expat.ParserCreate(namespace_separator='}')
    pending_namespaces = {}
    stack = []
    spans = []
    quotes = []
    nodes, flows = [], []
    process = None
    count = 0

    def refuse(category):
        raise ProjectionRefused(category, parser.CurrentByteIndex)

    def start(name, attributes):
        nonlocal count, process
        namespace, local = qname(name)
        count += 1
        if count > 25000 or len(stack) >= 16:
            refuse('XML_complexity_limit')
        context = dict(stack[-1]['namespaces']) if stack else {}
        context.update(pending_namespaces)
        pending_namespaces.clear()
        if not stack and (namespace, local) != (MODEL, 'definitions'):
            refuse('BPMN_definitions_namespace_required')
        if (namespace, local) == (MODEL, 'standardLoopCharacteristics'):
            refuse('quality_unsupported_standard_loop_before_both_converters')
        for attribute in lexical_attributes(source, parser.CurrentByteIndex):
            spelling = attribute['name']
            if spelling == 'xmlns' or spelling.startswith('xmlns:'):
                continue
            parts = spelling.split(':', 1)
            prefix, local_attribute = parts if len(parts) == 2 else ('', parts[0])
            uri = context.get(prefix, '') if prefix else ''
            if local_attribute == 'schemaLocation':
                if uri != XSI:
                    refuse('wrong_schema_hint_namespace')
                if stack or (namespace, local) != (MODEL, 'definitions'):
                    refuse('schema_hint_wrong_parent')
                if spans:
                    refuse('duplicate_expanded_XML_attribute')
                value = attributes[XSI + '}schemaLocation']
                raw_value = attribute['raw_value']
                if value != CANONICAL or raw_value != CANONICAL.encode():
                    category = ('noncanonical_raw_hint_lexeme'
                                if value.split() == CANONICAL.split() else 'noncanonical_hint_value')
                    refuse(category)
                raw = source[attribute['start']:attribute['end']]
                spans.append({'byte_start': attribute['start'], 'byte_length': len(raw),
                              'subtree_sha256': sha(raw), 'raw_utf8': raw.decode(),
                              'parent': {'namespace': MODEL, 'local_name': 'definitions', 'root': True},
                              'expanded_attribute': {'namespace': XSI, 'local_name': 'schemaLocation'},
                              'canonical_value': CANONICAL, 'separator_whitespace_not_removed': True})
                quotes.append(attribute['quote'])
            elif uri == XSI:
                refuse('unsupported_XSI_attribute')
        parent = stack[-1] if stack else None
        if (namespace, local) == (MODEL, 'process'):
            if process is not None:
                refuse('multiple_processes')
            process = {'id': attributes.get('id'), 'isExecutable': attributes.get('isExecutable', 'false') == 'true'}
        if parent and (parent['namespace'], parent['local']) == (MODEL, 'process'):
            if namespace == MODEL and local in NODE_KINDS:
                nodes.append({'id': attributes.get('id'), 'kind': NODE_KINDS[local], 'label': attributes.get('name', '')})
            elif (namespace, local) == (MODEL, 'sequenceFlow'):
                flows.append({'id': attributes.get('id'), 'source': attributes.get('sourceRef'),
                              'target': attributes.get('targetRef'), 'label': attributes.get('name', '')})
        stack.append({'namespace': namespace, 'local': local, 'namespaces': context})

    def declaration(version, encoding, standalone):
        if version != '1.0' or encoding is not None and encoding.lower().replace('-', '') != 'utf8':
            refuse('XML10_UTF8_required')

    parser.StartNamespaceDeclHandler = lambda prefix, uri: pending_namespaces.update({prefix or '': uri})
    parser.StartElementHandler = start
    parser.EndElementHandler = lambda name: stack.pop()
    parser.StartDoctypeDeclHandler = lambda *unused: refuse('DTD_forbidden_no_external_access')
    parser.EntityDeclHandler = lambda *unused: refuse('DTD_forbidden_no_external_access')
    parser.ExternalEntityRefHandler = lambda *unused: refuse('DTD_forbidden_no_external_access')
    parser.ProcessingInstructionHandler = lambda *unused: refuse('XML_PI_unsupported')
    parser.StartCdataSectionHandler = lambda: refuse('XML_CDATA_unsupported')
    parser.XmlDeclHandler = declaration
    try:
        parser.Parse(source, True)
    except ProjectionRefused:
        raise
    except expat.ExpatError as error:
        if error.code == expat.errors.codes[expat.errors.XML_ERROR_DUPLICATE_ATTRIBUTE]:
            try:
                start_offset = source.rfind(b'<', 0, parser.ErrorByteIndex + 1)
                names = [row['name'] for row in lexical_attributes(source, start_offset)]
                category = ('duplicate_XML_attribute' if len(set(names)) != len(names)
                            else 'duplicate_expanded_XML_attribute')
            except ProjectionRefused:
                category = 'duplicate_XML_attribute'
            raise ProjectionRefused(category, parser.ErrorByteIndex) from error
        raise ProjectionRefused('malformed_XML_or_namespace', parser.ErrorByteIndex) from error
    if process is None:
        raise ProjectionRefused('process_missing')
    pieces = []
    cursor = 0
    for span in spans:
        pieces.append(source[cursor:span['byte_start']])
        cursor = span['byte_start'] + span['byte_length']
    pieces.append(source[cursor:])
    projected = b''.join(pieces)
    return projected, {'schema_version': 1, 'projection_status': 'projected',
                       'category': 'canonical_root_hint_only' if spans else 'no_hint_noop',
                       'original_sha256': sha(source), 'original_bytes': len(source),
                       'projected_sha256': sha(projected), 'projected_bytes': len(projected),
                       'removed_spans': spans, 'attribute_quote_styles': quotes,
                       'semantic_map': {'process': process, 'nodes': nodes, 'flows': flows},
                       'never_resolve_schema': True, 'strict_projected_reparse_required': True,
                       'original_product_import_not_claimed': True,
                       'reference_must_receive_original_xml': True}


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
        result, report = project(source)
    except ProjectionRefused as error:
        report = {'schema_version': 1, 'projection_status': 'refused',
                  'category': error.category, 'byte_offset': error.offset,
                  'original_sha256': sha(source), 'original_bytes': len(source),
                  'projected_sha256': None, 'no_partial_projection': True}
        with args.report.open('x', encoding='utf-8') as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
        raise SystemExit(2)
    with args.output.open('xb') as stream:
        stream.write(result)
    with args.report.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
