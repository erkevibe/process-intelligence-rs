// Literal manually specified expectations: never inferred from either runtime.
import fs from 'node:fs';
import crypto from 'node:crypto';
const out = process.argv[2];
if (!out || fs.existsSync(out)) throw Error('Use a new corpus directory; no overwrite');
const event=(activity,timestamp=null,lifecycle=null)=>({activity,timestamp,lifecycle});
const fixtures=[
 {id:'reverse-ties',events:[event('B','2026-01-01T10:00:02Z'),event('A','2026-01-01T10:00:01Z'),event('C','2026-01-01T10:00:01Z')],timestamp_sequence:['A','C','B']},
 {id:'offset-equal',events:[event('B','2026-01-01T15:00:00+05:00'),event('A','2026-01-01T10:00:00Z')],timestamp_sequence:['B','A'],utc_millis:[1767261600000,1767261600000]},
 {id:'lifecycle',events:[event('A','2026-01-01T10:00:00Z','start'),event('A','2026-01-01T10:00:01Z','complete')],timestamp_sequence:['A','A']},
 {id:'missing-time',events:[event('A'),event('B','2026-01-01T10:00:00Z')],timestamp_error:'missing_timestamp'},
 {id:'invalid-time',events:[event('A','not-a-date')],rust_error:'invalid_timestamp',legacy:'observe-error'},
 {id:'wrong-time-type',events:[event('A','2026-01-01T10:00:00Z')],time_type:'string',rust_error:'invalid_timestamp',legacy:'observe-type'},
 {id:'duplicate-name',events:[event('A')],duplicate_name:'B',rust_error:'duplicate_key',legacy:'observe-duplicate'},
 {id:'empty-trace',events:[],timestamp_sequence:[]},
 {id:'unicode',events:[event('审批\nمرحبا'),event('終わり')],timestamp_error:'missing_timestamp'},
 {id:'submillisecond',events:[event('A','2026-01-01T10:00:00.123456Z')],timestamp_sequence:['A'],rust_timestamp:'2026-01-01T10:00:00.123456Z',legacy:'observe-precision'},
];
const escape=s=>s.replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;').replaceAll('\n','&#10;');
fs.mkdirSync(out,{recursive:true});
for(const f of fixtures){
 const body=f.events.map(e=>'<event><string key="concept:name" value="'+escape(e.activity)+'"/>'+(f.duplicate_name?'<string key="concept:name" value="'+f.duplicate_name+'"/>':'')+(e.timestamp?'<'+(f.time_type??'date')+' key="time:timestamp" value="'+e.timestamp+'"/>':'')+(e.lifecycle?'<string key="lifecycle:transition" value="'+e.lifecycle+'"/>':'')+'</event>').join('\n');
 const bytes=Buffer.from('<?xml version="1.0" encoding="UTF-8"?>\n<log xes.version="1.0"><string key="concept:name" value="'+f.id+'"/><trace><string key="concept:name" value="case-1"/>'+body+'</trace></log>\n');
 fs.writeFileSync(out+'/'+f.id+'.xes',bytes,{flag:'wx'});
 f.sha256=crypto.createHash('sha256').update(bytes).digest('hex');f.bytes=bytes.length;
 f.source_sequence=f.events.map(e=>e.activity);
}
fs.writeFileSync(out+'/corpus.json',JSON.stringify({schema_version:1,provenance:'Literal pre-execution manual expectations; error codes subject to independent source review before execution',parameters:{legacy_factory:'XFactoryNaiveImpl',classifier:'XEventNameClassifier',legacy_order:'XML source; no adapter sorting',manager_validateLog:'excluded',legacy_time:'java.util.Date milliseconds',rust_order:['source','timestamp']},fixtures},null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({directory:out,fixtures:fixtures.length}));
