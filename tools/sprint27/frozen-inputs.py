"""Independent exact generated-input lineage to committed prospective raw corpora."""
import importlib.util,json,re,xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('s27_frozen_audit',ROOT/'tools/sprint27/audit-rust-comparison.py');A=importlib.util.module_from_spec(spec);spec.loader.exec_module(A)
SETS={'original':('inputs01','fixtures/sprint26-miner/corpus.json',A.CORPUS),'validation':('inputs02','fixtures/sprint27-miner-validation/corpus.json','891b1f4306850ac0abd02a2afaeafa61a892847fbf2e73a44b02bdc06bbafa17'),'structured':('inputs03','fixtures/sprint27-structured/corpus.json','a6db9120518d4adfdfcb2648c6bba08efbd2757b4a36be50aafb50db795018e6')}
def validate(base,name):
    directory,corpus_path,wanted=SETS[name];raw=A.read(ROOT/corpus_path,1024*1024);A.need(A.sha(raw)==wanted,'actual_frozen_corpus_raw_hash')
    corpus=A.load(ROOT/corpus_path);A.need(corpus['schema_version']==1 and len(corpus['cases'])==7,'frozen_cases')
    expected={c['id']:c for c in corpus['cases']};A.need(len(expected)==len(corpus['cases']),'unique_frozen_ids')
    folder=base/directory;manifest=A.load(folder/'manifest.json');A.need(manifest['corpus_sha256']==wanted and manifest['training_only_xes'] is True and len(manifest['cases'])==7,'manifest_declaration')
    actual={c['id']:c for c in manifest['cases']};A.need(len(actual)==7 and set(actual)==set(expected),'exact_frozen_case_set')
    for identity,source in expected.items():
        A.need(re.fullmatch('[a-z][a-z0-9_]{0,63}',identity),'frozen_case_id');row=actual[identity]
        A.need(row['input_file']==identity+'.json' and row['xes_file']==identity+'.xes','exact_input_names')
        data=A.read(folder/row['input_file']);generated=A.load(folder/row['input_file'])
        wanted_case={key:source[key] for key in ('id','train','held_out')};wanted_case['diagnostic_only']=source.get('diagnostic_only',[])
        encode=lambda v:json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)
        A.need(encode(generated)==encode(wanted_case) and A.sha(data)==row['input_sha256'],'generated_case_exact_frozen_projection')
        for group in ('train','held_out','diagnostic_only'):
            rows=wanted_case[group];A.need(encode(row['counts'][group])==encode([sum(v['count'] for v in rows),sum(len(v['trace'])*v['count'] for v in rows)]),'frozen_weighted_counts')
        xes=A.read(folder/row['xes_file']);A.need(A.sha(xes)==row['xes_sha256'],'exact_xes_hash')
        traces=[]
        for trace in ET.fromstring(xes).findall('{*}trace'):
            sequence=[]
            for event in trace.findall('{*}event'):
                values=[v.attrib['value'] for v in event.findall('{*}string') if v.attrib.get('key')=='concept:name'];A.need(len(values)==1,'one_event_classifier');sequence.append(values[0])
            traces.append(tuple(sequence))
        train=Counter()
        for v in source['train']:train[tuple(v['trace'])]+=v['count']
        A.need(Counter(traces)==train,'training_xes_exact_frozen_variants')
    return manifest
