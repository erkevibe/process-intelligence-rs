"""Offline semantic-auditor tests on original synthetic BPMN, not miner runs."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('miner_semantic_audit',Path(__file__).with_name('audit-miner-performance.py'))
AUDIT=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)
NS='{http://www.omg.org/spec/BPMN/20100524/MODEL}'

def original(name):
    return (ROOT/'fixtures/quality-miner'/(name+'.bpmn')).read_bytes()

def xml(raw):
    return ET.fromstring(raw)

def serialized(root):
    return ET.tostring(root,encoding='utf-8',xml_declaration=True)

class SemanticAudit(unittest.TestCase):
    def test_originals_equal_without_scalar_quality_claim(self):
        for name in ['linear','exclusive-choice','parallel-interleavings','self-loop','short-loop','rare-noise','empty-trace']:
            with self.subTest(name=name):
                raw=original(name);result=AUDIT.compare(raw,raw)
                self.assertTrue(result['semantic_equal'])
                self.assertTrue(result['semantic_carry_gate_passed'])
                self.assertFalse(result['quality_carry_permitted'])
                self.assertEqual(len(result['complete_id_map']),len(set(r['candidate_id'] for r in result['complete_id_map'])))

    def test_full_identifier_renaming_and_prefix_serialization(self):
        raw=original('linear');root=xml(raw)
        ids={e.attrib['id']:'renamed_'+str(i) for i,e in enumerate(root.iter()) if 'id' in e.attrib}
        for e in root.iter():
            for key,value in list(e.attrib.items()):
                if key=='id' or key.rsplit('}',1)[-1] in AUDIT.REF_ATTRIBUTES or key.rsplit('}',1)[-1]=='bpmnElement':
                    if value in ids:e.set(key,ids[value])
            if e.tag.rsplit('}',1)[-1] in AUDIT.REF_TEXT and (e.text or '').strip() in ids:
                e.text=ids[e.text.strip()]
        result=AUDIT.compare(raw,serialized(root))
        self.assertTrue(result['semantic_equal'],result)

    def test_di_only_coordinates_and_editor_ids(self):
        raw=original('linear');root=xml(raw)
        for e in root.iter():
            if e.tag.startswith('{') and e.tag[1:].split('}',1)[0] in AUDIT.LAYOUT:
                if 'id' in e.attrib:e.set('id','editor_'+e.attrib['id'])
                if 'x' in e.attrib:e.set('x','12345')
                if 'y' in e.attrib:e.set('y','67890')
        self.assertTrue(AUDIT.compare(raw,serialized(root))['semantic_equal'])

    def test_label_mutation_same_counts_is_not_equal(self):
        raw=original('linear');root=xml(raw);root.find('.//'+NS+'task').set('name','different')
        self.assertFalse(AUDIT.compare(raw,serialized(root))['semantic_equal'])

    def test_loop_marker_and_loop_children_are_preserved(self):
        raw=original('self-loop');root=xml(raw)
        loop=root.find('.//'+NS+'standardLoopCharacteristics');self.assertIsNotNone(loop)
        loop.set('testBefore','true' if loop.get('testBefore')!='true' else 'false')
        self.assertFalse(AUDIT.compare(raw,serialized(root))['semantic_equal'])
        root=xml(raw);loop=root.find('.//'+NS+'standardLoopCharacteristics')
        ET.SubElement(loop,NS+'loopCondition').text='count < 3'
        self.assertFalse(AUDIT.compare(raw,serialized(root))['semantic_equal'])
        root=xml(raw)
        for parent in root.iter():
            for child in list(parent):
                if child.tag==NS+'standardLoopCharacteristics':parent.remove(child)
        self.assertFalse(AUDIT.compare(raw,serialized(root))['semantic_equal'])

    def test_flow_condition_and_endpoint_changes(self):
        raw=original('linear');root=xml(raw);flow=root.find('.//'+NS+'sequenceFlow')
        ET.SubElement(flow,NS+'conditionExpression').text='amount > 10'
        self.assertFalse(AUDIT.compare(raw,serialized(root))['semantic_equal'])
        root=xml(raw);flow=root.find('.//'+NS+'sequenceFlow');flow.set('targetRef',flow.get('sourceRef'))
        self.assertFalse(AUDIT.compare(raw,serialized(root))['semantic_equal'])

    def test_activity_event_and_process_semantic_attributes(self):
        raw=original('linear')
        for tag,key,value in [('task','isForCompensation','true'),('startEvent','isInterrupting','false'),('process','isExecutable','true')]:
            root=xml(raw);root.find('.//'+NS+tag).set(key,value)
            self.assertFalse(AUDIT.compare(raw,serialized(root))['semantic_equal'])

    def test_duplicate_and_dangling_ids_refused(self):
        raw=original('linear');root=xml(raw);elements=[e for e in root.iter() if 'id' in e.attrib];elements[1].set('id',elements[0].get('id'))
        self.assertEqual(AUDIT.compare(raw,serialized(root))['status'],'unsupported_or_invalid_semantics')
        root=xml(raw);root.find('.//'+NS+'sequenceFlow').set('sourceRef','missing-id')
        self.assertEqual(AUDIT.compare(raw,serialized(root))['status'],'unsupported_or_invalid_semantics')

    def test_unknown_semantic_namespace_not_ignored(self):
        raw=original('linear');root=xml(raw);root.find('.//'+NS+'task').set('{urn:unknown-behavior}constraint','x')
        result=AUDIT.compare(raw,serialized(root));self.assertFalse(result['semantic_equal']);self.assertEqual(result['status'],'unsupported_or_invalid_semantics')

    def test_timeout_is_inconclusive_not_pass(self):
        with patch.object(AUDIT.time,'monotonic',side_effect=[0,11,12]):
            result=AUDIT.compare(original('linear'),original('linear'))
        self.assertEqual(result['status'],'inconclusive_budget');self.assertFalse(result['semantic_equal'])

    def test_utf16_internal_dtd_cannot_bypass_declaration_guard(self):
        document=('<?xml version="1.0" encoding="UTF-16"?>'
                  '<!DOCTYPE definitions [<!ENTITY label "expanded">]>'
                  '<definitions xmlns="'+AUDIT.BPMN+'"><process id="p">'
                  '<task id="t" name="&label;"/></process></definitions>')
        for encoding in ['utf-16','utf-16-le','utf-16-be']:
            with self.subTest(encoding=encoding):
                raw=document.encode(encoding)
                # This is an actual parser-supported entity-expansion input,
                # rather than malformed XML that would fail independently.
                parsed=ET.fromstring(raw)
                self.assertEqual(parsed.find('.//'+NS+'task').get('name'),'expanded')
                result=AUDIT.compare(raw,raw)
                self.assertEqual(result['status'],'unsupported_or_invalid_semantics')
                self.assertFalse(result['semantic_equal'])
                self.assertFalse(result['semantic_carry_gate_passed'])
                self.assertFalse(result['quality_carry_permitted'])

    def test_utf8_dtd_and_invalid_utf8_refused(self):
        document=('<!DOCTYPE definitions [<!ENTITY label "expanded">]>'
                  '<definitions xmlns="'+AUDIT.BPMN+'"><process id="p">'
                  '<task id="t" name="&label;"/></process></definitions>').encode('utf-8')
        result=AUDIT.compare(document,document)
        self.assertEqual(result['reason'],'xml_declaration_or_entity')
        self.assertFalse(result['semantic_equal'])
        invalid=original('linear')+b'\xff'
        result=AUDIT.compare(invalid,invalid)
        self.assertEqual(result['status'],'unsupported_or_invalid_semantics')
        self.assertFalse(result['semantic_equal'])

if __name__=='__main__':
    unittest.main()
