// Original synthetic corpus, independent literal arithmetic. No legacy source.
import fs from 'node:fs';
import crypto from 'node:crypto';
const out=new URL('../../fixtures/oracle/',import.meta.url); fs.mkdirSync(out,{recursive:true});
const definitions=[
 {id:'alternatives',traces:[['A','B'],['A','C'],['A','B']],expected:{cases:3,events:6,activities:3,activity_counts:{A:3,B:2,C:1},variants:[{sequence:['A','B'],count:2},{sequence:['A','C'],count:1}],edges:[{source:'A',target:'B',count:2},{source:'A',target:'C',count:1}]}},
 {id:'self-loop',traces:[['A','A'],['A']],expected:{cases:2,events:3,activities:1,activity_counts:{A:3},variants:[{sequence:['A','A'],count:1},{sequence:['A'],count:1}],edges:[{source:'A',target:'A',count:1}]}},
 {id:'empty-trace',traces:[[],['A']],expected:{cases:2,events:1,activities:1,activity_counts:{A:1},variants:[{sequence:[],count:1},{sequence:['A'],count:1}],edges:[]}},
 {id:'unicode',traces:[['Проверка\n雪','Одобрить'],['Одобрить','Проверка\n雪']],expected:{cases:2,events:4,activities:2,activity_counts:{'Проверка\n雪':2,'Одобрить':2},variants:[{sequence:['Проверка\n雪','Одобрить'],count:1},{sequence:['Одобрить','Проверка\n雪'],count:1}],edges:[{source:'Проверка\n雪',target:'Одобрить',count:1},{source:'Одобрить',target:'Проверка\n雪',count:1}]}},
 {id:'lifecycle',traces:[['A','A','B']],lifecycles:[['start','complete','complete']],expected:{cases:1,events:3,activities:2,activity_counts:{A:2,B:1},variants:[{sequence:['A','A','B'],count:1}],edges:[{source:'A',target:'A',count:1},{source:'A',target:'B',count:1}]}},
 {id:'timestamp-order',traces:[['B','A','C']],timestamps:[['2026-01-01T00:00:02Z','2026-01-01T00:00:01Z','2026-01-01T00:00:01Z']],expected:{cases:1,events:3,activities:3,activity_counts:{A:1,B:1,C:1},variants:[{sequence:['B','A','C'],count:1}],edges:[{source:'B',target:'A',count:1},{source:'A',target:'C',count:1}]},timestamp_expected:{cases:1,events:3,activities:3,activity_counts:{A:1,B:1,C:1},variants:[{sequence:['A','C','B'],count:1}],edges:[{source:'A',target:'C',count:1},{source:'C',target:'B',count:1}]}}
];
const esc=s=>s.replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;').replaceAll('\n','&#10;').replaceAll('\r','&#13;');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
for(const d of definitions){
 const xml='<?xml version="1.0" encoding="UTF-8"?>\n<log xes.version="1.0">'+d.traces.map((t,i)=>'<trace><string key="concept:name" value="same-case-name"/>'+t.map((a,j)=>'<event><string key="concept:name" value="'+esc(a)+'"/>'+(d.lifecycles?'<string key="lifecycle:transition" value="'+d.lifecycles[i][j]+'"/>':'')+(d.timestamps?'<date key="time:timestamp" value="'+d.timestamps[i][j]+'"/>':'')+'</event>').join('')+'</trace>').join('')+'</log>\n';
 fs.writeFileSync(new URL(d.id+'.xes',out),xml); d.xes_sha256=sha(xml);
 // Token labels prevent the actual legacy text grammar from splitting newline/colon.
 d.label_tokens=Object.fromEntries([...new Set(d.traces.flat())].map(a=>['L'+Buffer.from(a,'utf8').toString('hex'),a]));
 const token=a=>'L'+Buffer.from(a,'utf8').toString('hex');
 d.normalized_text=d.traces.map(t=>'1::'+t.map(token).join('::')).join('\n')+'\n';
 fs.writeFileSync(new URL(d.id+'.txt',out),d.normalized_text); d.text_sha256=sha(d.normalized_text);
}
fs.writeFileSync(new URL('corpus.json',out),JSON.stringify({schema_version:1,provenance:'Literal PM arithmetic, not Rust/legacy generated expected values; independent QA review required',parameters:{order:'source',lifecycle:'each-event',classifier:'concept:name',missing_timestamp:'allowed in source order',legacy_adapter:'XES normalized traces -> frequency-prefixed text, lossless hex UTF-8 labels; not legacy XES importer'},fixtures:definitions},null,2)+'\n');
console.log('Frozen six fixtures; literal expected arithmetic retained.');
