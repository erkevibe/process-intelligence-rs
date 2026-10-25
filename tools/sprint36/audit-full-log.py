#!/usr/bin/env python3
"""Independent XML/language and integer-metric audit of the DFG state-machine profile."""
import collections
import copy
from fractions import Fraction
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

NS='{http://www.omg.org/spec/BPMN/20100524/MODEL}'

def audit(rows, xml, report):
    process=ET.fromstring(xml).find(NS+'process')
    assert process is not None
    nodes={};edges=[]
    for element in process:
        kind=element.tag.removeprefix(NS)
        if kind=='sequenceFlow':edges.append((element.attrib['sourceRef'],element.attrib['targetRef']))
        else:
            assert kind in ('startEvent','endEvent','task','exclusiveGateway'),kind
            key=element.attrib['id'];assert key not in nodes
            nodes[key]=(kind,element.attrib.get('name',''))
    assert len(edges)==len(set(edges))
    assert all(a in nodes and b in nodes for a,b in edges)
    incoming={k:[] for k in nodes};outgoing={k:[] for k in nodes}
    for a,b in edges:incoming[b].append(a);outgoing[a].append(b)
    starts=[k for k,(kind,_) in nodes.items() if kind=='startEvent']
    ends=[k for k,(kind,_) in nodes.items() if kind=='endEvent']
    assert len(starts)==len(ends)==1
    assert not incoming[starts[0]] and len(outgoing[starts[0]])==1
    assert not outgoing[ends[0]] and len(incoming[ends[0]])==1
    tasks={k:label for k,(kind,label) in nodes.items() if kind=='task'}
    assert len(tasks)==len(set(tasks.values()))
    assert all(label and len(incoming[k])==len(outgoing[k])==1 for k,label in tasks.items())
    def reachable(seed,adj):
        seen={seed};todo=[seed]
        while todo:
            for node in adj[todo.pop()]:
                if node not in seen:seen.add(node);todo.append(node)
        return seen
    assert reachable(starts[0],outgoing)==set(nodes)
    assert reachable(ends[0],incoming)==set(nodes)
    def next_labels(seed):
        seen=set();todo=list(outgoing[seed]);labels=set();terminal=False
        while todo:
            node=todo.pop()
            if node in seen:continue
            seen.add(node)
            if node in tasks:labels.add(tasks[node])
            elif node==ends[0]:terminal=True
            else:todo.extend(outgoing[node])
        return labels,terminal
    initial,empty=next_labels(starts[0])
    nexts={label:next_labels(k) for k,label in tasks.items()}
    expected_starts=set();expected_ends=set();expected_edges=set();expected_empty=False
    prefixes={};cases=0;events=0
    for row in rows:
        sequence=row['sequence'];frequency=row['frequency']
        assert isinstance(frequency,int) and frequency>0
        cases+=frequency;events+=frequency*len(sequence)
        if not sequence:expected_empty=True;assert empty;continue
        expected_starts.add(sequence[0]);expected_ends.add(sequence[-1])
        assert sequence[0] in initial and nexts[sequence[-1]][1]
        for a,b in zip(sequence,sequence[1:]):
            expected_edges.add((a,b));assert b in nexts[a][0]
        for length in range(1,len(sequence)):
            prefix=tuple(sequence[:length]);weight,labels=prefixes.setdefault(prefix,[0,set()])
            prefixes[prefix][0]=weight+frequency;labels.add(sequence[length])
    assert initial==expected_starts and empty==expected_empty
    assert {label for label,(_,terminal) in nexts.items() if terminal}==expected_ends
    assert {(a,b) for a,(labels,_) in nexts.items() for b in labels}==expected_edges
    activated=cases*len(initial);escaping=0
    for prefix,(weight,observed) in prefixes.items():
        enabled=nexts[prefix[-1]][0]
        activated+=weight*len(enabled);escaping+=weight*len(enabled-observed)
    metrics=report['metrics'];fitness=metrics['fitness'];precision=metrics['precision']
    assert report['trace_count']==cases and report['variant_count']==len(rows)
    assert fitness['status']=='measured' and fitness['fitness']['log_fitness']==1
    assert fitness['integer_components']['traces']==cases and fitness['integer_components']['events']==events
    assert fitness['integer_components']['weighted_total_cost']==0
    assert precision['status']=='measured'
    assert precision['numerator']==activated-escaping and precision['denominator']==activated
    places=len(edges)+2;transitions=0;arcs=0
    for node,(kind,_) in nodes.items():
        ni,no=len(incoming[node]),len(outgoing[node])
        if kind=='exclusiveGateway':transitions+=ni*no;arcs+=2*ni*no
        elif kind in ('startEvent','endEvent','task'):transitions+=1;arcs+=2
    vertices=places+transitions
    simplicity=Fraction(1) if arcs<=vertices else Fraction(vertices,2*arcs-vertices)
    actual=metrics['simplicity']
    assert (actual['places'],actual['transitions'],actual['arcs'])==(places,transitions,arcs)
    assert (actual['numerator'],actual['denominator'])==(simplicity.numerator,simplicity.denominator)
    return dict(status='FULL_LOG_INDEPENDENT_XML_AND_INTEGER_METRICS_PASS',cases=cases,events=events,variants=len(rows),activities=len(tasks),nodes=len(nodes),flows=len(edges),precision_numerator=activated-escaping,precision_denominator=activated,simplicity_numerator=simplicity.numerator,simplicity_denominator=simplicity.denominator,scope='Exact observed language containment and DFG adjacency, single-token completion, integer training metrics; no held-out independence claim')

if __name__=='__main__':
    if len(sys.argv)>=2 and sys.argv[1]=='--discovery-export':
        assert len(sys.argv) in (4,5),'audit-full-log.py --discovery-export DISCOVERY_JSON MODEL_BPMN [--self-test]'
        export=json.loads(Path(sys.argv[2]).read_text())
        assert export['algorithm']=='directly_follows_state_machine_v1'
        assert export['metadata']['profile']==export['artifact']['input']['profile']=='full_log_state_machine_v1'
        rows=export['artifact']['input']['variants'];xml=Path(sys.argv[3]).read_bytes();report=export['artifact']['output']['training_report']
    else:
        assert len(sys.argv) in (4,5),'audit-full-log.py VARIANTS_JSON MODEL_BPMN REPORT_JSON [--self-test]'
        rows=json.loads(Path(sys.argv[1]).read_text());xml=Path(sys.argv[2]).read_bytes();report=json.loads(Path(sys.argv[3]).read_text())
    result=audit(rows,xml,report)
    if len(sys.argv)==5:
        assert sys.argv[4]=='--self-test'
        changes=[]
        for section,key in [('precision','numerator'),('precision','denominator'),('simplicity','numerator')]:
            altered=copy.deepcopy(report);altered['metrics'][section][key]+=1;changes.append((rows,xml,altered))
        altered=copy.deepcopy(report);altered['metrics']['fitness']['integer_components']['events']+=1;changes.append((rows,xml,altered))
        altered=copy.deepcopy(rows);altered[0]['frequency']+=1;changes.append((altered,xml,report))
        tree=ET.fromstring(xml);process=tree.find(NS+'process');process.remove(process.find(NS+'sequenceFlow'));changes.append((rows,ET.tostring(tree),report))
        refused=0
        for args in changes:
            try:audit(*args)
            except (AssertionError,KeyError,ValueError):refused+=1
            else:raise AssertionError('semantic corruption accepted')
        result['semantic_refusal_controls']=refused
    print(json.dumps(result,indent=2))
