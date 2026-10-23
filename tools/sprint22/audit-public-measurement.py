"""Independent fixed-count saved measurement audit. No native, PG or network calls."""
import csv,hashlib,io,json,sys,time,xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime,timedelta,timezone
inputs,root,out=map(Path,sys.argv[1:4]);inputs=inputs.absolute();root=root.absolute();projection_path=Path(sys.argv[4]).absolute()
started=time.monotonic();APP='4121BD68F1C0C05A61B039FADF20FEC5C2DA4379D8AAAFB170DC3B43861D1525'
MANIFEST='59DA6F7A7A61826A579F93C394D1EFDF7DDEBE9D550E8120E1BB1EF8D5BDCC43';STAMP='2026-01-01T00:00:00.000000001Z'
def need(ok,why):
    if not ok:raise ValueError(why)
def bound():need(time.monotonic()-started<90,'audit90s')
def sha(b):return hashlib.sha256(b).hexdigest().upper()
def read(p,cap=32*1024*1024):
    bound();need(p.is_file() and p.stat().st_size<=cap,'regular_bounded_file')
    anchor=root.parent if p.absolute()==projection_path else inputs if p.absolute().is_relative_to(inputs) else root
    need(p.absolute().is_relative_to(anchor),'contained_input')
    q=p.absolute()
    while True:
        need(not q.is_symlink() and not(getattr(q.lstat(),'st_file_attributes',0)&1024),'no_reparse')
        if q==anchor:break
        q=q.parent
    with p.open('rb') as f:b=f.read(cap+1)
    need(len(b)<=cap,'read_cap');return b
def pairs(rows):
    d={}
    for k,v in rows:need(k not in d,'duplicate_json_key');d[k]=v
    return d
def parse(b):return json.loads(b,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite')))
def load(p,cap=32*1024*1024):return parse(read(p,cap))
def utc(s):return datetime.fromisoformat(s.replace('Z','+00:00'))
def csv_check(raw,count):
    rows=csv.reader(io.StringIO(raw.decode('utf-8'),newline=''),strict=True)
    need(next(rows,None)==['case','activity','timestamp','lifecycle'],'manual_csv_header');n=0
    for row in rows:
        need(row==['complexity-case','A',STAMP,''],'manual_csv_each_fixed_row');n+=1
    need(n==count,'manual_csv_count')
def identity(label,r,start):
    need(start['pid']==r['pid'] and start['native_creation_filetime']==r['native_creation_filetime'] and r['native_creation_filetime']>0,'native100ns_identity')
    floor=datetime(1601,1,1,tzinfo=timezone.utc)+timedelta(microseconds=r['native_creation_filetime']//10)
    need(utc(start['native_creation_utc'])==floor,'native_time_floor')
    need(start['program']==r['program'] and start['retained_native_handle'] and r['retained_native_handle'],'retained_image_handle')
    need(start['created_suspended'] and not start['resumed'] and start['job_member'] and start['collector_outside_job'],'suspended_job_admission')
    need(start['stdout_capture_ready'] and start['stderr_capture_ready'] and r['resumed'],'captures_before_resume')
need(not out.exists(),'fresh_output')
need(projection_path==root.parent/'projection-manifest.json','exact_projection_manifest_path')
projection=load(projection_path,4*1024*1024)
cluster_entries=[e for e in projection['entries'] if e['public_path']=='measurement/session/cluster-identity.stdout']
need(len(cluster_entries)==1,'one_cluster_projection')
cluster_projection=cluster_entries[0]
need(cluster_projection['source']=='workspace:/.local/sprint21/root/sprint22/measurement01/session/cluster-identity.stdout' and cluster_projection['mode']=='json_paths' and cluster_projection['json_pointers']==['/data_directory'] and not cluster_projection.get('uri_pointers') and not cluster_projection.get('guard_message_pointers') and not cluster_projection.get('memory_ndjson'),'only_cluster_data_directory_projection')
manifest_raw=read(inputs/'manifest.json',65536);need(sha(manifest_raw)==MANIFEST,'immutable_manifest')
manifest=parse(manifest_raw);need([(c['id'],c['events']) for c in manifest['cases']]==[('CMP10K',10000),('CMP90K',90000)],'fixed_order_counts')
method=load(root/'method-before-first-observation.json');need(method['input_manifest_sha256']==MANIFEST and method['app_sha256']==APP,'method_before_input_identity')
need(method['observations_per_case']==1 and method['retuning_or_repeated_submissions_allowed'] is False,'fixed_single_observation')
session=root/'session';broker=load(session/'broker-result.json');stop=utc(broker['stop_utc'])
need(broker['stop_reason']=='worker_exit' and broker['failure'] is None and not broker['kill_fault'] and broker['guard_failure'] is None,'actual_broker_success')
need(not broker['absolute_stop_timer_fired'],'absolute_guard_not_expired')
need(stop<=utc(broker['kill_requests_completed_utc'])<=utc(broker['cleanup_completed_utc'])<utc(broker['collector_finalization_deadline']),'bounded_finalization')
probe=broker['post_stop_probe'];need(probe['attempted'] and probe['refused'] and probe['exception_code']=='stop_latched_no_admission' and probe['resume_unchanged'] and probe['process_count_before']==probe['process_count_after'],'actual_no_go_after_stop')
required={'worker','postgres','cluster-identity','create-db','ready-01','app10k','app90k','child','http90k','source10k','source90k','pg-stop'}
paths=list(session.glob('*.process.json'));labels={p.name[:-len('.process.json')] for p in paths}
need(required<=labels and len(labels)<=32 and all(l in required or (l.startswith('ready-') and l[6:].isdigit()) for l in labels),'mandatory_native_labels')
records={};stream_count=0
for p in paths:
    label=p.name[:-len('.process.json')];r=load(p,65536);records[label]=r;st=load(session/(label+'.start.json'),65536);identity(label,r,st)
    need(utc(st['utc'])<=utc(r['resume_utc'])<=stop and r['native_exit'] is not None,'actual_resume_exit')
    expected=[137] if label in ['app10k','app90k'] else [0,1,2] if label.startswith('ready-') else [0]
    need(r['native_exit'] in expected and r['source_status']=='captured' and not r['drain_timeout'],'native_exit_or_status')
    if label in ['app10k','app90k']:need(st['program_sha256']==APP,'fixed_app_native_sha')
    for side in ['stdout','stderr']:
        raw=read(session/(label+'.'+side));stream_count+=1
        need(r[side+'_capture_initialized'] and r[side+'_eof'] and r[side+'_complete'] and not r[side+'_truncated'] and not r[side+'_fault'],'full_actual_native_eof')
        if label=='cluster-identity' and side=='stdout':
            e=cluster_projection
            need(r[side+'_bytes_persisted']==r[side+'_bytes_observed']==e['original_bytes'] and r[side+'_sha256'].upper()==e['original_sha256'].upper(),'original_cluster_native_descriptor_not_rebound')
            need(len(raw)==e['public_bytes'] and sha(raw)==e['public_sha256'].upper(),'projected_cluster_representation_binding')
            expected={'data_directory':'workspace:/.local/sprint21/root/pgdata11','port':'55449','database':'postgres','user':'pi_s21_admin','in_recovery':False}
            need(parse(raw)==expected,'exact_cluster_alias_and_unchanged_nonpath_values')
            need(e['numeric_tokens_sha256_before']==e['numeric_tokens_sha256_after']==hashlib.sha256(b'').hexdigest(),'cluster_original_numeric_lexemes')
        else:
            need(len(raw)==r[side+'_bytes_persisted']==r[side+'_bytes_observed'] and sha(raw)==r[side+'_sha256'].upper(),'raw_native_hash_length')
need(any(records[l]['native_exit']==0 for l in labels if l.startswith('ready-')),'actual_ready0')
need(broker['process_count']==broker['completed_count']==len(records),'all_owned_records')
for label in ['postgres','app10k','app90k']:
    w=broker['service_watchers'][label];need(w['expected_exit'] is True and w['triggered'] is False and utc(w['attached_utc'])<=utc(records[label]['resume_utc']),'service_expected_before_resume')
barrier=broker['sample_barrier'];need(barrier['window_seconds']==19 and barrier['periodic_seconds']==20 and barrier['scanner_unchanged'] is True,'fresh_pgstop_barrier')
need(barrier['absolute_deadline_ticks']-barrier['completed_ticks']==19*barrier['frequency'],'fixed_monotonic_pgstop_deadline')
need((stop-utc(barrier['completed_utc'])).total_seconds()<19,'pgstop_before_absolute_deadline')
cluster=load(session/'cluster-identity.stdout',65536);need(cluster['port']=='55449' and cluster['database']=='postgres' and cluster['user']=='pi_s21_admin' and cluster['in_recovery'] is False,'actual_owned_cluster')
need(Path(cluster['data_directory']).name=='pgdata11','actual_cluster_path')
results=[]
for case in manifest['cases']:
    bound();count=case['events'];tag='10k' if count==10000 else '90k';folder=root/('http-'+tag)
    source=read(inputs/case['input_file'],20*1024*1024);need(sha(source)==case['input_sha256'] and len(source)==case['input_bytes'],'frozen_source_bytes')
    x=ET.fromstring(source);traces=list(x.findall('{*}trace'));need(len(traces)==1,'manual_xml_one_trace')
    events=traces[0].findall('{*}event');need(len(events)==count,'manual_xml_fixed_events')
    for e in events:
        attrs={a.attrib.get('key'):a.attrib.get('value') for a in e}
        need(attrs=={'concept:name':'A','time:timestamp':STAMP},'manual_xml_fixed_values')
    need(any(a.attrib.get('key')=='concept:name' and a.attrib.get('value')=='complexity-case' for a in traces[0] if a.tag.endswith('string')),'manual_xml_trace_name')
    oracle_raw=read(inputs/case['oracle_file'],65536);need(sha(oracle_raw)==case['oracle_sha256'],'frozen_oracle')
    manual=read(inputs/case['manual_csv_file'],8*1024*1024);need(sha(manual)==case['manual_csv_sha256'],'frozen_manual_csv');csv_check(manual,count)
    r=load(folder/'result.json');meta=r['metadata'];snap=r['outcome']
    need(r['status']=='OBSERVATION_COMPLETED' and r['case']==case['id'] and r['events_expected']==count and r['submitted_conversions']==1,'single_case_observation')
    need(r['app_sha256']==APP and r['input_manifest_sha256']==MANIFEST and r['input_sha256']==sha(source) and r['input_bytes']==len(source),'observed_input_binding')
    need(meta['snapshot']==snap and meta['source_sha256'].upper()==sha(source) and meta['input_bytes']==len(source) and meta['from']=='xes' and meta['to']=='csv' and meta['allow_loss'] is False,'http_terminal_metadata')
    uploads=[e for e in r['events'] if e['method']=='POST' and e['path']=='/conversions'];need(len(uploads)==1 and uploads[0]['status']==303,'one_actual_accepted_upload')
    need(r['case_wall_seconds']<=120 and all(e.get('request_wall_seconds',999)<=15.05 for e in r['events']),'actual_http_wall_bounds')
    sql=load(session/('source'+tag+'.stdout'));need(len(sql['rows'])==1,'one_actual_pg_record');record=sql['rows'][0]
    project=[p for p in sql['projects'] if p['project_id']==r['project_id']];need(len(project)==1,'actual_project')
    need(project[0]['conversions'][r['job_id']]==meta and record['project_id']==r['project_id'] and record['resource_id']==r['artifact_id']==meta['artifact_id'],'full_durable_http_metadata_identity')
    doc=record['document'];need(doc['input'].encode()==source,'independent_pg_original_source_bytes')
    if snap['state']=='completed':
        pair={}
        for part in ['payload','report']:
            d=r['downloads'][part];raw=read(folder/d['file'],20*1024*1024 if part=='payload' else 4*1024*1024);pair[part]=raw
            need(d['available'] is True and d['http_status']==200 and sha(raw)==d['sha256']==meta[part+'_sha256'].upper() and len(raw)==d['bytes'],'actual_download_bytes')
            need(doc[part].encode()==raw,'actual_pg_pair_bytes')
        csv_check(pair['payload'],count);report=parse(pair['report']);ev=report['evidence']
        need(report['status']=='converted' and report['input_sha256'].upper()==sha(source) and report['input_bytes']==len(source) and report['target_sha256'].upper()==sha(pair['payload']) and report['target_bytes']==len(pair['payload']) and report['allow_metadata_loss'] is False,'report_identity')
        need(ev['event_count']==count and ev['trace_count']==1 and ev['metadata_loss_count']==0 and ev['losses']==[],'report_manual_counts_loss')
        for core in [ev['source_core'],ev['target_core']]:
            need(len(core['traces'])==1 and core['traces'][0]['name']=='complexity-case' and len(core['traces'][0]['events'])==count,'report_trace_count')
            need(all(e=={'activity':'A','timestamp':STAMP,'lifecycle':None} for e in core['traces'][0]['events']),'report_manual_each_event')
    else:
        need(snap['state']=='failed' and snap['error']['code']=='report_byte_limit' and snap['result_id'] is None,'declared_failed_outcome_only')
        need(doc['payload'] is None and doc['report'] is None,'durable_failed_no_pair')
        for part in ['payload','report']:need(r['downloads'][part]=={'available':False,'http_status':404} and meta[part+'_sha256'] is None,'actual_failed_pair404')
    memory_raw=read(root/('memory-'+tag+'.ndjson'),4*1024*1024);lines=[parse(l) for l in memory_raw.splitlines()];head,footer=lines[0],lines[-1];samples=lines[1:-1]
    app=records['app'+tag];mp=load(root/('memory-'+tag+'-proof.json'),65536)
    need(head['kind']=='header' and head['pid']==app['pid']==mp['pid'] and head['creation_filetime']==app['native_creation_filetime']==mp['native_creation_filetime'] and head['image_verified'],'memory_native_identity')
    need(2<=len(samples)<=5000 and len(memory_raw)==mp['bytes'] and sha(memory_raw)==mp['sha256'] and mp['samples']==len(samples),'complete_memory_hash_bound')
    need(footer=={'kind':'complete','samples':len(samples),'target_still_alive':True},'actual_complete_memory_footer')
    for n,s in enumerate(samples,1):
        need(s['kind']=='sample' and s['number']==n and s['stage'] in ['startup','warm_before','http_client','warm_after'],'memory_actual_stage_sequence')
        for key in ['working_set','private_commit','lifetime_peak_working_set','lifetime_peak_commit','page_faults']:need(type(s[key]) is int and s[key]>=0,'memory_native_integer')
        need(s['working_set']<=s['lifetime_peak_working_set'],'native_peak_ge_sample')
        if n>1:need(utc(samples[n-2]['utc'])<=utc(s['utc']),'memory_observation_time')
    need(samples[-1]['stage']=='warm_after' and utc(samples[-1]['utc'])<utc(app['completed_utc']),'fresh_final_alive_sample_before_teardown')
    results.append({'case':case['id'],'events':count,'state':snap['state'],'manual_source_pair_or_refusal_verified':True,'memory_samples':len(samples),'sampled_max_working_set':max(s['working_set'] for s in samples),'sampled_max_private_commit':max(s['private_commit'] for s in samples),'native_lifetime_peak_working_set_through_final_alive_sample':samples[-1]['lifetime_peak_working_set'],'native_lifetime_peak_commit_through_final_alive_sample':samples[-1]['lifetime_peak_commit']})
need(records['app10k']['pid']!=records['app90k']['pid'] or records['app10k']['native_creation_filetime']!=records['app90k']['native_creation_filetime'],'separate_fresh_app_lifetimes')
outer=load(root/'collector.process.json',65536);need(outer['native_exit']==0 and outer['stdout_complete'] and outer['stderr_complete'] and not outer['capture_fault'] and not outer['drain_timeout'] and not outer['output_limit'],'actual_outer_native_closure')
for side in ['stdout','stderr']:
    b=read(root/('collector.'+side));need(len(b)==outer[side+'_bytes_persisted'] and sha(b)==outer[side+'_sha256'].upper(),'outer_raw_bytes')
proof=load(root/'measurement-proof.json');need(proof['native_records']==len(records) and proof['historical_unknowns']==6 and proof['historical_unknowns_repaired'] is False,'final_root_proof_count_history')
need(proof['broker_result_sha256']==sha(read(session/'broker-result.json')),'final_broker_hash')
bound()
with out.open('x',encoding='utf-8') as f:json.dump({'status':'INDEPENDENT_PUBLIC_TWO_FIXED_OBSERVATIONS_WITH_ONE_EXPLICIT_PROJECTED_NATIVE_REPRESENTATION','cases':results,'session_native_records':len(records),'session_full_source_stream_slots':stream_count,'session_exact_original_raw_streams':stream_count-1,'projected_native_representations':1,'all_exact_original_public_raw_streams_including_outer':stream_count+1,'outer_native_exit_and_both_eof':True,'historical_unknowns_unchanged':6,'limits':['Server memory excludes PG/client; sampled maxima are not lifetime peaks or RAM limits.','Fixed repeated values do not prove ordering sensitivity or graph diversity.','No CPU/SLO/browser/enterprise claim or historical UNKNOWN repair.','One cluster-identity stdout is a manifest-bound path-projected representation; native descriptor retains its original private full-capture SHA/length. Other27public raw streams remain exact original bytes.','Saved-data audit performs no product/PG/native/network execution.']},f,indent=2)