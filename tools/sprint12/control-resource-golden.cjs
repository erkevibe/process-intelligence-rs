'use strict';
// Literal expectations for the public order.csv / order-source.xes / linear.bpmn.
// No product parser or miner is imported by this fixture oracle.
const csvData={name:null,cases:[
 {id:'case-0',name:'c1',events:[{ordinal:0,activity:'A',timestamp:'2026-10-12T05:00:00Z',lifecycle:'complete'},{ordinal:2,activity:'C',timestamp:'2026-10-12T04:00:00Z',lifecycle:'start'},{ordinal:4,activity:'B',timestamp:'2026-10-12T04:00:00Z',lifecycle:'complete'}]},
 {id:'case-1',name:'c2',events:[{ordinal:1,activity:'A',timestamp:'2026-10-12T04:00:00Z',lifecycle:'complete'},{ordinal:3,activity:'B',timestamp:'2026-10-12T05:00:00Z',lifecycle:'complete'}]},
],warnings:[]};
const xesData=structuredClone(csvData);xesData.cases.forEach(c=>c.events.forEach((e,i)=>e.ordinal=i));xesData.warnings=['Предварительный просмотр: исходные данные не изменены. Это не полный сервис Apromore.'];
const analysis={cases:2,events:5,activities:3,nodes:[
 {id:'activity-0',label:'A',count:2,start_count:2,end_count:0},
 {id:'activity-1',label:'B',count:2,start_count:0,end_count:2},
 {id:'activity-2',label:'C',count:1,start_count:0,end_count:0},
],edges:[{id:'edge-0',source:'activity-0',target:'activity-1',count:1},{id:'edge-1',source:'activity-0',target:'activity-2',count:1},{id:'edge-2',source:'activity-2',target:'activity-1',count:1}],variants:[{id:'variant-0',sequence:['A','B'],count:1,case_ids:['case-1']},{id:'variant-1',sequence:['A','C','B'],count:1,case_ids:['case-0']}],max_edge_frequency:1};
const filteredData=structuredClone(csvData);filteredData.cases.forEach(c=>c.events=c.events.filter(e=>e.activity!=='C'));
const filteredAnalysis={cases:2,events:4,activities:2,nodes:analysis.nodes.slice(0,2),edges:[{id:'edge-0',source:'activity-0',target:'activity-1',count:2}],variants:[{id:'variant-0',sequence:['A','B'],count:2,case_ids:['case-0','case-1']}],max_edge_frequency:2};
const filters={case_activity:null,min_events:null,max_events:null,retain_activities:[],remove_activities:[]};
const calendar={offset_minutes:0,weekdays:[1,2,3,4,5],start_minute:540,end_minute:1080,holidays:[]};
const model={schema_version:1,process_id:'p',name:'Қазақ & test',nodes:[
 {id:'s',kind:'start',label:'',x:10.5,y:20},
 {id:'a',kind:'task',label:'A & "quote"\nline',x:100,y:-20.25},
 {id:'b',kind:'task',label:'B',x:420,y:80},
 {id:'e',kind:'end',label:'',x:590,y:80},
],flows:[{id:'sa',source:'s',target:'a',waypoints:[]},{id:'ab',source:'a',target:'b',waypoints:[{x:200,y:20},{x:300.5,y:40}]},{id:'be',source:'b',target:'e',waypoints:[]}],discovery:null};
function rustModelJson(m){
 return JSON.stringify({schema_version:m.schema_version,process_id:m.process_id,name:m.name,
  nodes:m.nodes.map(n=>({id:n.id,kind:n.kind,label:n.label,x:n.x,y:n.y})),
  flows:m.flows.map(f=>({id:f.id,source:f.source,target:f.target,waypoints:f.waypoints.map(p=>({x:p.x,y:p.y}))})),discovery:m.discovery})
  .replace(/"(x|y)":(-?\d+)(?=[,}])/g,(_,key,value)=>`"${key}":${value}.0`);
}
module.exports={csvData,xesData,analysis,filteredData,filteredAnalysis,filters,calendar,model,rustModelJson};
