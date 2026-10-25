#!/usr/bin/env python3
"""Independent shortest-edit-cost replay over the delivered sequential BPMN language."""
from fractions import Fraction
import heapq
import importlib.util
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

def audit(train,control,xml,report):
    spec=importlib.util.spec_from_file_location('full_log_audit',Path(__file__).with_name('audit-full-log.py'))
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    helper.audit(train,xml,report['training'])
    ns=helper.NS;process=ET.fromstring(xml).find(ns+'process')
    kinds={};out={}
    for e in process:
        if e.tag==ns+'sequenceFlow':out.setdefault(e.attrib['sourceRef'],[]).append(e.attrib['targetRef'])
        else:kinds[e.attrib['id']]=(e.tag.removeprefix(ns),e.attrib.get('name',''))
    start=next(k for k,(kind,_) in kinds.items() if kind=='startEvent')
    end=next(k for k,(kind,_) in kinds.items() if kind=='endEvent')
    tasks={k:label for k,(kind,label) in kinds.items() if kind=='task'}
    ids=[start]+sorted(tasks);index={k:i for i,k in enumerate(ids)}
    adjacency=[];terminal=[]
    for node in ids:
        seen=set();todo=list(out.get(node,[]));targets=[];done=False
        while todo:
            k=todo.pop()
            if k in seen:continue
            seen.add(k)
            if k in tasks:targets.append((index[k],tasks[k]))
            elif k==end:done=True
            else:todo.extend(out.get(k,[]))
        adjacency.append(targets);terminal.append(done)
    def cost(sequence):
        queue=[(0,0,0)];dist={(0,0):0}
        while queue:
            value,state,pos=heapq.heappop(queue)
            if dist.get((state,pos))!=value:continue
            if terminal[state] and pos==len(sequence):return value
            moves=[]
            if pos<len(sequence):moves.append((state,pos+1,1))
            for target,label in adjacency[state]:
                moves.append((target,pos,1))
                if pos<len(sequence) and sequence[pos]==label:moves.append((target,pos+1,0))
            for target,next_pos,extra in moves:
                key=(target,next_pos);candidate=value+extra
                if candidate<dist.get(key,float('inf')):dist[key]=candidate;heapq.heappush(queue,(candidate,target,next_pos))
        raise AssertionError('no accepting model path')
    empty=cost([]);weighted=0;nonfitting=0;cases=0;events=0
    for row in control:
        n=row['frequency'];c=cost(row['sequence']);cases+=n;events+=n*len(row['sequence']);weighted+=n*c;nonfitting+=n*(c!=0)
    metric=report['control']['metrics'];components=metric['fitness']['integer_components'];denominator=events+cases*empty
    assert components==dict(traces=cases,events=events,empty_cost=empty,weighted_total_cost=weighted,log_denominator=denominator)
    assert abs(metric['fitness']['fitness']['log_fitness']-float(Fraction(denominator-weighted,denominator)))<1e-12
    if weighted:
        assert metric['precision']['status']=='requires_fitting_log'
        assert metric['precision']['scalar'] is None
        assert metric['precision']['nonfitting_trace_frequency']==nonfitting
    assert report['held_out_supplied_to_miner'] is False
    return dict(status='HOLDOUT_INDEPENDENT_SHORTEST_EDIT_COST_PASS',control_cases=cases,control_events=events,nonfitting_cases=nonfitting,weighted_total_cost=weighted,log_denominator=denominator,log_fitness_numerator=denominator-weighted,log_fitness_denominator=denominator,scope='Independent model language and optimum edit costs; source case-disjointness follows the separately fixed extraction protocol, not an author signature')

if __name__=='__main__':
    assert len(sys.argv)==5,'audit-holdout.py TRAIN_JSON CONTROL_JSON MODEL_BPMN HOLDOUT_REPORT_JSON'
    print(json.dumps(audit(json.loads(Path(sys.argv[1]).read_text()),json.loads(Path(sys.argv[2]).read_text()),Path(sys.argv[3]).read_bytes(),json.loads(Path(sys.argv[4]).read_text())),indent=2))
