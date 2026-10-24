"""Freeze own public-service inputs and source-derived hypotheses before execution."""
import hashlib
import json
from pathlib import Path

base = Path(__file__).resolve().parents[2] / 'fixtures/oracle-public-service'
base.mkdir(exist_ok=False)
head = '<?xml version="1.0" encoding="UTF-8"?>\n<log xmlns="http://www.xes-standard.org/" xes.version="1.0">\n'
event = '<event><string key="concept:name" value="A"/><date key="time:timestamp" value="2024-01-01T00:00:00.123456Z"/><int key="cost" value="7"/><boolean key="approved" value="true"/></event>'
typed = head + '<string key="department" value="synthetic"/><classifier name="Activity lifecycle" keys="concept:name lifecycle:transition"/><global scope="event"><string key="resource" value="global-default"/></global><trace><string key="concept:name" value="case-1"/><float key="weight" value="1.5"/>' + event + '</trace></log>\n'
invalid = head + '</log>\n'
ordered = head + '<string key="concept:name" value="order"/><trace><string key="concept:name" value="case-order"/><event><string key="concept:name" value="B"/><date key="time:timestamp" value="2024-01-01T00:00:01.999999Z"/><string key="lifecycle:transition" value="start"/></event><event><string key="concept:name" value="A"/><date key="time:timestamp" value="2024-01-01T05:00:00+05:00"/><string key="lifecycle:transition" value="complete"/></event></trace></log>\n'
filtered = head + '<trace><event><string key="concept:name" value="removed"/><date key="time:timestamp" value="2024-01-01T00:00:00Z"/><string key="lifecycle:transition" value="suspend"/></event></trace></log>\n'
files = {'typed-defaults.xes': typed, 'invalid-empty.xes': invalid, 'order-offset.xes': ordered, 'all-filtered.xes': filtered}
for name, text in files.items():
    (base / name).write_text(text, encoding='utf-8', newline='\n')
personal = {'s18-alice': [True, True, True]}
inherited = {**personal, 's18-team': [True, False, False]}
cases = [
    ('minimal-home-private','typed-defaults.xes',None,False,'Public gate',{'outcome':'success','folder':'home','rights':personal,'log_delta':1,'storage_delta':1,'stored_traces':1,'stored_events':1}),
    ('owned-folder-private','typed-defaults.xes','owned',False,'Owned import',{'outcome':'success','folder':'owned','rights':inherited,'log_delta':1,'storage_delta':1}),
    ('foreign-folder-redirect','typed-defaults.xes','foreign',False,'Foreign import',{'outcome':'success','folder':'home','rights':personal,'log_delta':1,'storage_delta':1}),
    ('owned-folder-public','typed-defaults.xes','owned',True,'Public import',{'outcome':'success','folder':'owned','rights':{**inherited,'s18-public':[True,True,False]},'log_delta':1,'storage_delta':1}),
    ('unknown-user','typed-defaults.xes',None,False,'Unknown import',{'outcome':'exception','exception_class':'org.apromore.exception.UserNotFoundException','log_delta':0,'storage_delta':0,'file_delta':0,'cache_delta':0}),
    ('invalid-log','invalid-empty.xes',None,False,'Invalid import',{'outcome':'exception','exception_message':'No process instances contained in log!','log_delta':0,'storage_delta':0,'file_delta':0,'cache_delta':0}),
    ('outer-rollback','typed-defaults.xes','owned',False,'Rollback import',{'outcome':'outer_rollback','log_delta':0,'storage_delta':0,'external_effects':'observe exact file/cache delta; do not presume JPA rollback covers them'}),
    ('duplicate-owned-name','typed-defaults.xes','owned',False,'Duplicate import',{'outcome':'exception','log_delta':0,'storage_delta':0,'external_effects':'observe exact file/cache delta after actual DB unique constraint failure; seed baseline duplicate first'}),
    ('name-normalization','typed-defaults.xes',None,False,' report.v1. ',{'outcome':'success','normalized_name':'report_v1','folder':'home','rights':personal,'log_delta':1,'storage_delta':1}),
    ('order-offset-lifecycle','order-offset.xes',None,False,'Order import',{'outcome':'success','stored_activities':['B','A'],'stored_timestamp_millis':[1704067201999,1704067200000],'stored_lifecycle':['start','complete'],'log_delta':1,'storage_delta':1}),
    ('all-filtered','all-filtered.xes',None,False,'Filtered import',{'outcome':'success','stored_traces':0,'stored_events':0,'log_delta':1,'storage_delta':1,'apm_cache':'absent for empty converted log'})
]
rows = []
for cid, file, folder, public, name, expected in cases:
    rows.append({'id':cid,'file':file,'sha256':hashlib.sha256((base/file).read_bytes()).hexdigest(),
      'username':'s18-missing' if cid=='unknown-user' else 's18-alice','folder':folder,'public_model':public,
      'perspective':False,'log_name':name,'extension':'xes','domain':'s18-domain','created':'2026-10-21',
      'expected_source_hypothesis':expected})
manifest = {'schema_version':1,'scope':'Actual unchanged public importLog selected username/perspective=false path with real reachable Spring/JPA/H2/FILE/cache/APMLog; no Portal/MySQL/fullR2 claim',
 'source_commit':'bbf24dfd43e72d6992392465f875a4367cbe792b','corpus':rows,
 'typed_metadata_hypotheses':{'typed-defaults.xes':{'default_log_name':'Anonymous log imported from ','missing_lifecycle_default':'complete','custom_flat_types':'retain log string/trace float/event int+boolean','classifiers':'retain exact name/key order','globals':'retain global metadata; do not materialize missing event resource','timestamp':'actual OpenXES millisecond precision; raw nanoseconds not retained'},'order-offset.xes':{'event_order':'retain input event order','offset':'normalize to same instant at millisecond precision'}},
 'invariant_policy':['Freeze hypotheses before execution, preserve every false hypothesis as actual mismatch','Each scenario fresh private DB/file/cache state; duplicate scenario has declared seeded baseline','Actual transaction advisor and active transaction entry required for transactional claim','Unknownuser/parser failures expected no persistence/cache/file side effects','Owned/foreign checks use persisted GroupFolder rights, never stub authorization','Restart closes Spring/H2/cache and opens existing file database with schema validation; typed storage readback bound to saved key','No fixture expectation of dynamic storage timestamp or assigned numeric identity','External file/cache side effects on rollback observed independently; no atomic rollback claim from DB annotations']}
path=base/'corpus.json'
path.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'cases':len(rows),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'path':str(path)}))
