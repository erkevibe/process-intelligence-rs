"""Exact bounded exported-BPMN semantic isomorphism, never a miner/evaluator.

ID spelling and whole DI/DC layout subtrees are the only removed model data.
Color hashes prune candidates; a complete literal graph-bijection check is the
proof. Search exhaustion is inconclusive, never equality or quality carry.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import io
import json
from pathlib import Path
import time
import xml.etree.ElementTree as ET

BPMN = 'http://www.omg.org/spec/BPMN/20100524/MODEL'
XSI = 'http://www.w3.org/2001/XMLSchema-instance'
LAYOUT = {'http://www.omg.org/spec/BPMN/20100524/DI', 'http://www.omg.org/spec/DD/20100524/DI', 'http://www.omg.org/spec/DD/20100524/DC'}
REF_ATTRIBUTES = {'sourceRef','targetRef','default','attachedToRef','processRef','activityRef','messageRef','signalRef','errorRef','escalationRef','operationRef','itemSubjectRef','eventDefinitionRef','calledElement','participantRef','dataObjectRef','dataStoreRef'}
REF_TEXT = {'incoming','outgoing','flowNodeRef','eventDefinitionRef','sourceRef','targetRef','resourceRef','categoryValueRef'}
LITERAL_TEXT = {'conditionExpression','loopCondition','completionCondition','loopCardinality','documentation','script','expression','formalExpression'}
FLOW_ELEMENTS = {'task','userTask','serviceTask','scriptTask','sendTask','receiveTask','manualTask','businessRuleTask','callActivity','subProcess','transaction','adHocSubProcess','startEvent','endEvent','intermediateCatchEvent','intermediateThrowEvent','boundaryEvent','exclusiveGateway','inclusiveGateway','parallelGateway','complexGateway','eventBasedGateway','sequenceFlow','dataObject','dataObjectReference','dataStoreReference','textAnnotation','association','group','laneSet'}

class Refusal(ValueError):
    pass

class Budget(Refusal):
    pass

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def split(name):
    if name is ET.Comment:
        return '', '#comment'
    if name is ET.ProcessingInstruction:
        return '', '#processing-instruction'
    if name.startswith('{'):
        namespace,local = name[1:].split('}',1)
        return namespace,local
    return '',name

def encoded(value):
    return json.dumps(value,ensure_ascii=False,separators=(',',':'),sort_keys=True).encode('utf-8')

class Graph:
    def __init__(self, raw, deadline):
        self.raw_sha256=sha(raw)
        self.vertices=[]
        self.edges=[]
        self.ids={}
        self.exclusions=[]
        self.deadline=deadline
        if len(raw)>4*1024*1024:
            raise Refusal('xml_byte_cap')
        # Decode strictly before inspection and give the parser this same text;
        # XML byte-encoding autodetection must not bypass declaration checks.
        text=raw.decode('utf-8',errors='strict')
        if '\x00' in text:
            raise Refusal('xml_nul_or_non_utf8_encoding')
        if '<!DOCTYPE' in text.upper() or '<!ENTITY' in text.upper():
            raise Refusal('xml_declaration_or_entity')
        namespaces={}
        pending=[]
        stack=[]
        parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True,insert_pis=True))
        events=ET.iterparse(io.StringIO(text),events=('start','end','start-ns'),parser=parser)
        root=None
        for event,value in events:
            self.guard()
            if event=='start-ns':
                pending.append(value)
            elif event=='start':
                current=dict(stack[-1]) if stack else {}
                current.update(pending);pending=[];stack.append(current)
                namespaces[id(value)]=current
                if root is None:
                    root=value
            else:
                stack.pop()
        if root is None or root.tag!='{'+BPMN+'}definitions':
            raise Refusal('bpmn_definitions_required')
        self.namespaces=namespaces
        self._visit(root,None,None)
        if len(self.ids)>256:
            raise Budget('semantic_id_element_cap')
        id_to_index={key:index for key,index in self.ids.items()}
        refs=0
        for i,vertex in enumerate(self.vertices):
            for role,target in vertex.pop('_references'):
                refs+=1
                if refs>512:
                    raise Budget('reference_edge_cap')
                if target not in id_to_index:
                    raise Refusal('unresolved_semantic_reference:'+target)
                self.edges.append((i,id_to_index[target],role))
        self.out=defaultdict(list);self.incoming=defaultdict(list);self.between=defaultdict(Counter)
        for a,b,role in self.edges:
            self.out[a].append((role,b));self.incoming[b].append((role,a));self.between[a,b][role]+=1
        self.colors=[encoded({key:value for key,value in v.items() if key not in ['id','index']}).decode('utf-8') for v in self.vertices]

    def guard(self):
        if time.monotonic()>self.deadline:
            raise Budget('comparison_time_cap')

    def _qname_value(self, element, text):
        if ':' not in text:
            namespace=self.namespaces.get(id(element),{}).get('','')
            return '{'+namespace+'}'+text if namespace else text
        prefix,local=text.split(':',1)
        namespace=self.namespaces.get(id(element),{}).get(prefix)
        if namespace is None:
            raise Refusal('unresolved_qname_prefix')
        return '{'+namespace+'}'+local

    def _visit(self, element, parent_index, child_position):
        self.guard()
        namespace,local=split(element.tag)
        if namespace in LAYOUT:
            representation=ET.tostring(element,encoding='utf-8')
            self.exclusions.append({'qname':element.tag,'parent_index':parent_index,'parsed_subtree_serialization_sha256':sha(representation),'parsed_subtree_utf8':representation.decode('utf-8'),'hash_is_not_claimed_as_original_raw_byte_span':True})
            return
        if namespace not in [BPMN,''] or (namespace=='' and local not in ['#comment','#processing-instruction']):
            raise Refusal('unknown_semantic_element_namespace:'+namespace)
        index=len(self.vertices)
        attributes=[];references=[];identity=None
        for key,value in sorted(element.attrib.items()):
            ans,attr=split(key)
            if key=='id':
                if not value or value in self.ids:
                    raise Refusal('empty_or_duplicate_semantic_id')
                identity=value;self.ids[value]=index
            elif ans in ['',BPMN] and attr in REF_ATTRIBUTES:
                target=value.strip()
                if not target or ':' in target or any(c.isspace() for c in target):
                    raise Refusal('unsupported_or_empty_idref:'+key)
                references.append(('attribute-reference:'+key,target))
            elif key=='{'+XSI+'}type':
                attributes.append((key,self._qname_value(element,value)))
            elif ans in ['',BPMN,XSI]:
                attributes.append((key,value))
            else:
                raise Refusal('unknown_semantic_attribute_namespace:'+ans)
        text=element.text or ''
        if namespace==BPMN and local in REF_TEXT:
            target=text.strip()
            if not target or ':' in target or any(c.isspace() for c in target):
                raise Refusal('unsupported_or_empty_text_reference')
            references.append(('text-reference:'+local,target));text=''
        elif local not in LITERAL_TEXT and text.isspace():
            text=''
        significant_tails=[]
        semantic_position=0
        for child in element:
            if split(child.tag)[0] not in LAYOUT:
                semantic_position+=1
            tail=child.tail or ''
            if tail and (local in LITERAL_TEXT or not tail.isspace()):
                significant_tails.append((semantic_position-1,tail))
        self.vertices.append({'index':index,'id':identity,'has_id':identity is not None,'qname':element.tag if isinstance(element.tag,str) else local,'attributes':attributes,'text':text,'significant_tails':significant_tails,'_references':references})
        if parent_index is not None:
            parent=self.vertices[parent_index]
            pns,plocal=split(parent['qname'])
            unordered=(namespace==BPMN and local in ['incoming','outgoing']) or (pns==BPMN and plocal in ['process','subProcess','transaction','adHocSubProcess'] and namespace==BPMN and local in FLOW_ELEMENTS) or (pns==BPMN and plocal=='definitions' and namespace==BPMN and local in ['process','collaboration','message','signal','error','escalation','itemDefinition','resource','interface','category'])
            role='contains-unordered' if unordered else 'contains-ordered:'+str(child_position)
            self.edges.append((parent_index,index,role))
        semantic_position=0
        for child in element:
            excluded=split(child.tag)[0] in LAYOUT
            self._visit(child,index,semantic_position)
            if not excluded:
                semantic_position+=1

    def public(self):
        return {'raw_sha256':self.raw_sha256,'vertices':self.vertices,'edges':[{'source':a,'target':b,'role':role} for a,b,role in self.edges],'excluded_layout':self.exclusions}

def compare(baseline,candidate):
    start=time.monotonic();deadline=start+10;attempts=0
    result={'schema_version':1,'baseline_sha256':sha(baseline),'candidate_sha256':sha(candidate),'semantic_equal':False,'semantic_carry_gate_passed':False,'quality_carry_permitted':False,'quality_carry_requires_separate_historical_case_admission_and_metric_source_binding':True,'not_a_quality_evaluator':True,'no_hash_only_isomorphism_claim':True}
    try:
        left=Graph(baseline,deadline);right=Graph(candidate,deadline)
        result['baseline_semantics']=left.public();result['candidate_semantics']=right.public()
        if len(left.vertices)!=len(right.vertices) or len(left.edges)!=len(right.edges) or len(left.ids)!=len(right.ids):
            result.update(status='different_semantics',reason='element_reference_or_id_cardinality');return result
        n=len(left.vertices)
        palette={value:i for i,value in enumerate(sorted(set(left.colors+right.colors)))}
        a=[palette[value] for value in left.colors];b=[palette[value] for value in right.colors]
        while True:
            left.guard();right.guard()
            if Counter(a)!=Counter(b):
                result.update(status='different_semantics',reason='full_literal_or_refined_partition');return result
            def signature(graph,index,colors):
                return (colors[index],tuple(sorted((role,colors[target]) for role,target in graph.out[index])),tuple(sorted((role,colors[source]) for role,source in graph.incoming[index])))
            sa=[signature(left,i,a) for i in range(n)];sb=[signature(right,i,b) for i in range(n)]
            p={value:i for i,value in enumerate(sorted(set(sa+sb)))}
            na=[p[value] for value in sa];nb=[p[value] for value in sb]
            stable=len(set(na+nb))==len(set(a+b));a,b=na,nb
            if stable:
                break
        if Counter(a)!=Counter(b):
            result.update(status='different_semantics',reason='refined_partition');return result
        choices={i:[j for j in range(n) if a[i]==b[j]] for i in range(n)}
        mapping={};used=set()
        def search():
            nonlocal attempts
            left.guard()
            if len(mapping)==n:
                transformed=Counter((mapping[x],mapping[y],role) for x,y,role in left.edges)
                return transformed==Counter(right.edges) and all(left.colors[i]==right.colors[j] for i,j in mapping.items())
            todo=[i for i in range(n) if i not in mapping]
            node=min(todo,key=lambda i:(sum(j not in used for j in choices[i]),-len(left.out[i])-len(left.incoming[i]),i))
            for other in choices[node]:
                left.guard()
                if other in used:
                    continue
                attempts+=1
                if attempts>1000000:
                    raise Budget('candidate_assignment_cap')
                if left.between[node,node]!=right.between[other,other]:
                    continue
                if any(left.between[node,i]!=right.between[other,j] or left.between[i,node]!=right.between[j,other] for i,j in mapping.items()):
                    continue
                mapping[node]=other;used.add(other)
                if search():
                    return True
                used.remove(other);del mapping[node]
            return False
        equal=search()
        result.update(status='exact_full_semantic_bijection' if equal else 'different_semantics',semantic_equal=equal,semantic_carry_gate_passed=equal,quality_carry_permitted=False)
        if equal:
            result['complete_element_map']=[{'baseline_index':i,'candidate_index':mapping[i],'qname':left.vertices[i]['qname']} for i in range(n)]
            result['complete_id_map']=[{'baseline_id':identity,'candidate_id':right.vertices[mapping[index]]['id'],'qname':left.vertices[index]['qname']} for identity,index in sorted(left.ids.items())]
            if len({r['candidate_id'] for r in result['complete_id_map']})!=len(left.ids):
                raise Refusal('nonbijective_id_map')
    except Budget as error:
        result.update(status='inconclusive_budget',reason=str(error),semantic_equal=False,semantic_carry_gate_passed=False,quality_carry_permitted=False)
    except RecursionError:
        result.update(status='inconclusive_budget',reason='recursion_stack_limit',semantic_equal=False,semantic_carry_gate_passed=False,quality_carry_permitted=False)
    except (Refusal,ET.ParseError,UnicodeError,ValueError) as error:
        result.update(status='unsupported_or_invalid_semantics',reason=str(error),semantic_equal=False,semantic_carry_gate_passed=False,quality_carry_permitted=False)
    finally:
        result['candidate_assignments']=attempts;result['audit_wall_seconds']=time.monotonic()-start
    return result

def bounded(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size>4*1024*1024:
        raise ValueError('regular bounded XML file required')
    return path.read_bytes()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    result=compare(bounded(args.baseline),bounded(args.candidate))
    with args.output.open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(result,stream,ensure_ascii=False,indent=2);stream.write('\n')
    print(json.dumps({'status':result['status'],'semantic_equal':result['semantic_equal'],'semantic_carry_gate_passed':result['semantic_carry_gate_passed'],'quality_carry_permitted':result['quality_carry_permitted']}))

if __name__=='__main__':
    main()
