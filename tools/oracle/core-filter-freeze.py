"""Freeze own eight-case filter corpus before any engine/filters::apply execution."""
import hashlib
import json
from pathlib import Path

workspace=Path(__file__).resolve().parents[2]
base=workspace/'fixtures/oracle-core-filter'
contract=workspace/'docs/R5_CASE_ACTIVITY_REFERENCE_CONTRACT.md'
assert hashlib.sha256(contract.read_bytes()).hexdigest()=='8dfb1c10096cf04a6279a8cadd9d2c4100fcf924155b0a0fc0bf6a402938ef6a'
base.mkdir(exist_ok=False)
cases=[
 ('membership',[['A','B'],['a','B'],['C','A']],['A'],[0,2],[0,2],'overlap'),
 ('no-match',[['A'],['B']],['Z'],[],[],'overlap'),
 ('duplicate-activities',[['A','A','B','A'],['B','B']],['A'],[0],[0],'overlap'),
 ('unicode-exact',[['É'],['E\u0301'],['é']],['É'],[0],[0],'overlap'),
 ('ordered-composition',[['A','B'],['A'],['B'],['B','A']],['A','B'],[0,3],[0,3],'overlap'),
 ('no-rules',[['A'],['B']],[],[0,1],[0,1],'overlap'),
 ('empty-literal',[['A'],['B']],[''],[],[0,1],'diagnostic_sentinel_difference'),
 ('empty-input',[],['A'],None,[],'diagnostic_converter_refusal'),
]
rows=[]
for cid,traces,literals,java_indices,rust_indices,profile in cases:
    source={'name':'Core filter '+cid,'cases':[],'warnings':['synthetic source warning retained']}
    for index,activities in enumerate(traces):
        events=[]
        for j,activity in enumerate(activities):
            # Non-contiguous ordinals and descending timestamps detect accidental
            # event renumbering or timestamp sorting by an adapter/filter.
            events.append({'ordinal':3+j*7,'activity':activity,
                           'timestamp':f'2024-01-01T00:00:{40-j:02d}.123Z','lifecycle':'complete'})
        source['cases'].append({'id':f'{cid}-source-{index}','name':f'{cid}-trace-{index}','events':events})
    value={'schema_version':1,'id':cid,'rule_literals':literals,'source':source}
    path=base/(cid+'.json')
    path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    java_ids=None if java_indices is None else [source['cases'][i]['id'] for i in java_indices]
    rust_ids=[source['cases'][i]['id'] for i in rust_indices]
    rows.append({'id':cid,'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                 'profile':profile,'rule_literals':literals,
                 'expected_java':{'status':'converter_refused' if java_indices is None else 'filtered',
                                  'engine_invoked':java_indices is not None,'selected_trace_indices':java_indices,
                                  'selected_source_case_ids':java_ids,
                                  'source_xlog_unchanged':True,'source_apm_unchanged':None if java_indices is None else True,
                                  **({'exception_class':'org.apromore.apmlog.exceptions.EmptyInputException'} if java_indices is None else {})},
                 'expected_rust':{'status':'filtered','selected_source_case_ids':rust_ids,'source_unchanged':True},
                 'full_identity_expectation':'Keep original selected complete source cases, event order, sparse ordinals, descending timestamps, lifecycle, names and warning metadata; no adapter predicate'})
manifest={'schema_version':1,'kind':'FROZEN_BEFORE_EXECUTION_GENUINE_CORE_CASE_ACTIVITY_FILTER_REFERENCE',
 'contract_path':'docs/R5_CASE_ACTIVITY_REFERENCE_CONTRACT.md','contract_sha256':hashlib.sha256(contract.read_bytes()).hexdigest(),
 'core_commit':'bbf24dfd43e72d6992392465f875a4367cbe792b','canonical_jar_sha256':'4fc0c2cdd170c1f5cbf4fe542250c7b84deb2dfc583dc10631b6562b3894ef81',
 'engine_class_sha256':'b07c241d7d5a430f9fd1f6cea5eb696a71eefdee7dc268ee0c81d18c464769b3',
 'parameters':{'filter_type':'CASE_EVENT_ATTRIBUTE','choice':'RETAIN','inclusion':'ANY_VALUE','section':'CASE','key':'concept:name','rule_value_operation':'EQUAL','one_java_ordered_rule_list':True},
 'input_schema':'case JSON.source is exact existing Rust EventLog serde shape; rule_literals array retains order; Java source case IDs/ordinals additionally copied into synthetic XES attributes',
 'cases':rows,'scope':['First six overlap cases; final two are declared diagnostic differences, never equality PASS',
 'Actual whole original engine and real converter; no source edits, mocks, extracted predicates or toy fallback',
 'Java repeat-call reset behavior is not sequential AND composition; only one ordered rule list is compared',
 'No entire Core/R5, numeric length/event projection/calendar/conversion/miner quality claim'],
 'no_engine_or_rust_filter_execution_before_freeze':True}
path=base/'corpus.json'
path.write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
print(json.dumps({'manifest_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'cases':len(rows),'path':str(path)}))
