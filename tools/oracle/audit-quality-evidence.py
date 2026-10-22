"""Independent audit of saved finite quality evidence; no metric engine is invoked.

Replays every measured alignment against the conserved complete marking graph,
recomputes optimal costs by graph-product Dijkstra, exact rational aggregates,
and all minimum-tau prefix stops/closures. Checks input coverage before metrics.
Refused and inconclusive outcomes remain explicit; this is not R4 acceptance.
Run without Python -O: assertions are intentional fail-closed audit predicates.
"""
import argparse
import collections
import hashlib
import heapq
import importlib.util
import json
import pathlib
from fractions import Fraction

if not __debug__:
 raise RuntimeError('audit_requires_assertions_enabled')

def raw(path):
 path=pathlib.Path(path)
 assert path.is_file() and not path.is_symlink() and path.stat().st_size<=32*1024*1024, 'input_type_or_size'
 value=path.read_bytes()
 assert len(value)<=32*1024*1024, 'input_grew'
 return value

def load(path):
 return json.loads(raw(path))

def H(path):
 return hashlib.sha256(raw(path)).hexdigest()

def saved_net(directory,name):
 assert isinstance(name,str) and name not in {'.','..'} and '/' not in name and '\\' not in name and ':' not in name
 return directory/'nets'/name

def close(a,b):assert abs(float(a)-float(b))<1e-9,(a,b)
def verify(graph,net,groups,rgroups,limits):
 edges=collections.defaultdict(list)
 for e in graph['edges']:edges[e['from']].append(e)
 initial=graph['initial_state'];final=set(graph['final_states']);markids={tuple(m):i for i,m in enumerate(graph['states'])}
 encoding={label:f'L{i:06d}' for i,label in enumerate(sorted({e['label'] for e in graph['edges'] if e['label'] is not None}))}
 def optimum(seq):
  queue=[(0,initial,0)];seen={}
  while queue:
   cost,s,p=heapq.heappop(queue)
   if (s,p) in seen:continue
   seen[s,p]=cost
   if s in final and p==len(seq):return cost
   if p<len(seq):heapq.heappush(queue,(cost+1,s,p+1))
   for e in edges[s]:
    heapq.heappush(queue,(cost+(e['label'] is not None),e['to'],p))
    if e['label'] is not None and p<len(seq) and e['label']==seq[p]:heapq.heappush(queue,(cost,e['to'],p+1))
   assert len(seen)<=100000
  raise AssertionError('no alignment')
 def replay(seq,moves,cost,pm=False):
  s=initial;p=0;v=0
  for mv in moves:
   if pm:
    (traceid,t),(ll,ml)=mv
    if t=='>>':
     assert traceid!='>>' and p<len(seq) and ll==encoding[seq[p]] and ml=='>>'
     p+=1;v+=1;continue
    kind='ModelMove' if traceid=='>>' else 'SyncMove';tid=t
   else:
    kind,x=next(iter(mv.items()))
    if kind=='LogMove':assert x['trace_event_index']==p;p+=1;v+=1;continue
    tid=x['transition']
    if kind=='SyncMove':assert x['trace_event_index']==p
   matches=[e for e in edges[s] if e['transition']==tid];assert len(matches)==1,(s,tid);e=matches[0]
   if pm:
    assert ml==(None if e['label'] is None else encoding[e['label']])
    assert ll==('>>' if kind=='ModelMove' else encoding[seq[p]])
   if kind=='SyncMove':assert p<len(seq) and e['label']==seq[p];p+=1
   else:v+=e['label'] is not None
   s=e['to']
  assert s in final and p==len(seq) and v==cost==optimum(seq),(s,p,v,cost)
 def closure(starts,limit):
  seen=set(starts);q=list(starts)
  if len(seen)>limit:raise ValueError('tau_closure_budget')
  while q:
   for e in edges[q.pop()]:
    if e['label'] is None and e['to'] not in seen:
     seen.add(e['to']);q.append(e['to'])
     if len(seen)>limit:raise ValueError('tau_closure_budget')
  return seen
 def prefix(seq,limit):
  q=[(0,initial,0)];dist={(initial,0):0};settled=set();stops=set();best=None
  while q:
   cost,s,p=heapq.heappop(q)
   if best is not None and cost>best:break
   if (s,p) in settled or cost!=dist[s,p]:continue
   settled.add((s,p))
   if p==len(seq):stops.add(s);best=cost;continue
   for e in edges[s]:
    if e['label'] is None:np=p;inc=1
    elif e['label']==seq[p]:np=p+1;inc=0
    else:continue
    key=(e['to'],np);v=cost+inc
    if key not in dist or v<dist[key]:
     if key not in dist and len(dist)>=limit:raise ValueError('prefix_search_budget')
     dist[key]=v;heapq.heappush(q,(v,e['to'],np))
  return stops,best
 checked=[]
 for group in groups:
  name=group['group'];m=group['metrics'];ref=next(g['result'] for g in rgroups if g['group']==name);rows=group['input'];counts=collections.Counter()
  for row in rows:counts[tuple(row['sequence'])]+=row['frequency']
  encoding={label:f'L{i:06d}' for i,label in enumerate(sorted({e['label'] for e in graph['edges'] if e['label'] is not None}|{label for seq in counts for label in seq}))}
  simple=m['simplicity'];v=len(net['places'])+len(net['transitions']);arcs=len(net['arcs']);simp=Fraction(v,2*arcs-v) if arcs>v else Fraction(1);assert simple['places']==len(net['places']) and simple['transitions']==len(net['transitions']) and simple['arcs']==arcs;assert Fraction(simple['numerator'],simple['denominator'])==simp;close(simple['scalar'],simp)
  if 'simplicity' in ref:close(ref['simplicity']['scalar'],simp)
  fit=m['fitness'];pr=m['precision']
  if not counts:assert fit['status']==pr['status']==ref['fitness']['status']==ref['precision']['status']=='no_data';checked.append({'group':name,'fitness':'no_data','precision':'no_data'});continue
  assert fit['status']=='measured';empty=fit['empty_alignment'];replay([],empty['moves'],empty['cost']);aligned={tuple(x['activities']):x for x in fit['alignments']};assert {k:x['frequency'] for k,x in aligned.items()}==dict(counts)
  cost=den=perfect=0;avg=Fraction(0);traces=sum(counts.values())
  for seq,f in counts.items():
   x=aligned[seq]['result']['Ok'];replay(seq,x['moves'],x['cost']);dd=len(seq)+empty['cost'];cost+=f*x['cost'];den+=f*dd;perfect+=f*(x['cost']==0);avg+=f*(1-Fraction(x['cost'],dd) if dd else 1)
  log=1-Fraction(cost,den) if den else Fraction(1);avg/=traces;close(fit['fitness']['log_fitness'],log);close(fit['fitness']['average_fitness'],avg);close(fit['fitness']['perfectly_fitting_frac'],Fraction(perfect,traces));assert fit['fitness']['total_costs']==cost
  if ref.get('status')!='reference_inconclusive':assert ref['fitness']['status']=='measured' and ref['activity_encoding']==encoding
  else:assert ref['reason'] in {'reference_prefix_upper_bound_inconclusive','reference_tau_closure_upper_bound_inconclusive'}
  if ref.get('fitness',{}).get('status')=='measured':
   rf=ref['fitness'];assert Fraction(rf['log_fitness'])==log and Fraction(rf['average_trace_fitness'])==avg and Fraction(rf['perfectly_fitting_frac'])==Fraction(perfect,traces);replay([],rf['empty_alignment']['alignment'],rf['empty_alignment']['cost'],True)
   for x in rf['alignments']:replay(x['activities'],x['result']['alignment'],x['result']['cost'],True)
  if cost:assert pr['status']==ref['precision']['status']=='requires_fitting_log';checked.append({'group':name,'log':str(log),'precision':'requires_fitting_log'});continue
  prefixes={():[traces,{s[0] for s in counts if s}]}
  for seq,f in counts.items():
   for n in range(1,len(seq)):
    w,l=prefixes.setdefault(seq[:n],[0,set()]);prefixes[seq[:n]][0]+=f;l.add(seq[n])
  at=ee=0;expected={};cap=None
  try:
   for seq,(w,observed) in sorted(prefixes.items()):
    stops,best=({initial},0) if not seq else prefix(seq,limits['prefix']);cl=closure(stops,limits['tau']);labels={e['label'] for s in cl for e in edges[s] if e['label'] is not None};extra=labels-observed;at+=w*len(labels);ee+=w*len(extra);expected[seq]=(w,stops,cl,labels,extra,best)
  except ValueError as e:cap=str(e)
  if cap:assert pr['status']=='inconclusive' and pr['reason']==cap and ref['status']=='reference_inconclusive' and ref['reason']=={'prefix_search_budget':'reference_prefix_upper_bound_inconclusive','tau_closure_budget':'reference_tau_closure_upper_bound_inconclusive'}[cap];checked.append({'group':name,'precision':cap});continue
  assert len(pr['prefixes'])==len(expected)
  for x in pr['prefixes']:
   seq=tuple(x['prefix']);w,st,cl,la,ex,best=expected[seq];assert x['weight']==w and set(x['stop_markings'])==st and set(x['tau_closure_markings'])==cl and set(x['activated_labels'])==la and set(x['escaping_labels'])==ex;assert x['search']['minimum_tau_cost']==best
  if not at:assert pr['status']=='not_applicable_no_activated_labels' and pr['scalar'] is None;score=None
  else:score=Fraction(at-ee,at);assert Fraction(pr['numerator'],pr['denominator'])==score;close(pr['scalar'],score)
  rp=ref.get('precision',{})
  for x in rp.get('prefixes', []):
   seq=tuple(x['prefix']);w,st,cl,la,ex,best=expected[seq]
   assert x['weight']==w and set(x['activated_labels'])==la and set(x['escaping_labels'])==ex
   assert set(x['observed_next_labels'])==prefixes[seq][1]
   actual_stops=set()
   for marking in x['stop_markings']:
    assert set(marking)<=set(graph['places'])
    actual_stops.add(markids[tuple(marking.get(p,0) for p in graph['places'])])
   assert actual_stops==st
  if rp.get('empty_prefix') is not None:
   ep=rp['empty_prefix'];assert ep['weight']==traces and set(ep['activated_labels'])==expected[()][3] and set(ep['observed_next_labels'])==prefixes[()][1]
  assert rp['status']==('measured' if at else 'not_applicable_no_activated_labels')
  if rp.get('status')=='measured':assert score==Fraction(rp['rational']) and rp['activated_weight']==at and rp['escaping_weight']==ee
  checked.append({'group':name,'log':str(log),'average':str(avg),'precision':str(score),'activated':at,'escaping':ee,'simplicity':str(simp),'reference_status':rp.get('status',ref.get('status'))})
 return checked

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--rust',type=pathlib.Path,required=True)
 parser.add_argument('--reference',type=pathlib.Path,required=True)
 parser.add_argument('--prepared',type=pathlib.Path,required=True)
 parser.add_argument('--corpus',type=pathlib.Path,required=True)
 parser.add_argument('--output',type=pathlib.Path,required=True)
 args=parser.parse_args()
 R=load(args.rust);F=load(args.reference);bundle=load(args.prepared/'bundle.json');corpus=load(args.corpus)
 assert R['bundle_sha256']==F['bundle_sha256']==H(args.prepared/'bundle.json')
 assert bundle['corpus_sha256']==F['corpus_sha256']==H(args.corpus)
 spec=importlib.util.spec_from_file_location('quality_net_conservation',pathlib.Path(__file__).with_name('validate-quality-net-graph.py'))
 conservation=importlib.util.module_from_spec(spec);spec.loader.exec_module(conservation)
 expected={}
 for parent in corpus['cases']:
  main={k:v for k,v in parent.items() if k!='subcases'}
  rows=([main] if 'model' in main or 'manual_net' in main else [])+[{**main,**child} for child in parent.get('subcases',[])]
  for row in rows:
   assert row['id'] not in expected,'duplicate_frozen_case'
   expected[row['id']]=row
 assert len(R['cases'])==len(expected) and {c['id'] for c in R['cases']}==set(expected)
 refs={(x['id'],x['artifact_id']):x for x in F['cases']}
 assert len(refs)==len(F['cases']),'duplicate_reference_artifact'
 seen=set();report=[];graphs=0
 for c in R['cases']:
  assert c['frozen_input_and_hypothesis']==expected[c['id']],'frozen_case_changed'
  expected_artifacts=({f"bridge-{c['frozen_input_and_hypothesis']['model']}"} if 'model' in c['frozen_input_and_hypothesis'] else set())|({f"manual-{c['frozen_input_and_hypothesis']['manual_net']}"} if 'manual_net' in c['frozen_input_and_hypothesis'] else set())
  assert {m['artifact_id'] for m in c['measurements']}==expected_artifacts and len(c['measurements'])==len(expected_artifacts)
  for m in c['measurements']:
   key=(c['id'],m['artifact_id']);assert key not in seen;seen.add(key)
   result=m['result'];ref=refs[key]
   if 'groups' not in result:
    report.append({'id':c['id'],'artifact':m['artifact_id'],'status':result.get('status'),'reason':result.get('reason')});continue
   rec=bundle['artifacts'][m['artifact_id']]['prepared'];netpath=saved_net(args.prepared,rec['net_file']);netbytes=raw(netpath);net=json.loads(netbytes)
   assert H(netpath)==rec['net_sha256']==result['graph']['net_sha256']==ref['net_sha256']
   conservation.validate(netbytes,result['graph']);graphs+=1
   for groups in [result['groups'],ref['groups']]:
    assert len(groups)==2 and {g['group'] for g in groups}=={'training_log','heldout_log'}
    for g in groups:assert g['input']==expected[c['id']][g['group']],'log_input_changed'
   checked=verify(result['graph'],net,result['groups'],ref['groups'],c['limits'])
   report.append({'id':c['id'],'artifact':m['artifact_id'],'groups':checked})
 assert seen==set(refs),'reference_coverage_changed'
 output={'schema_version':1,'status':'independent_saved_evidence_audit_passed','rust_sha256':H(args.rust),'reference_sha256':H(args.reference),'corpus_sha256':H(args.corpus),'bundle_sha256':H(args.prepared/'bundle.json'),'case_rows':len(expected),'artifact_rows':len(report),'conserved_scored_graphs':graphs,'checks':report,'scope':'Exact input coverage, conserved nets/graphs, independent optimal-cost/path/prefix/rational checks; actual refusal reasons retained, not all hypotheses or R4 accepted.'}
 with args.output.open('x',encoding='utf-8',newline='\n') as stream:json.dump(output,stream,ensure_ascii=True,indent=2);stream.write('\n')
 print(json.dumps({'status':output['status'],'case_rows':len(expected),'artifact_rows':len(report),'output_sha256':H(args.output)}))

if __name__=='__main__':
 main()
