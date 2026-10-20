// Execute the actual browser script against controlled DOM/Cytoscape surfaces.
// This is a finite JS behavior regression, not a real-browser acceptance proof.
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const path = require('node:path');
const sourcePath = path.resolve('static/platform.js');
const source = fs.readFileSync(sourcePath, 'utf8');
const model = { schema_version: 1, process_id: 'p', name: 'M', discovery: null,
 nodes: [
  { id: 's', kind: 'start', label: '', x: 10, y: 20, dimensions: { width: 36, height: 36 } },
  { id: 'a', kind: 'task', label: 'A', x: 100, y: -20.25, dimensions: { width: 100, height: 80 } },
  { id: 'e', kind: 'end', label: '', x: 500, y: 20 }
 ], flows: [
  { id: 'sa', source: 's', target: 'a', waypoints: [{ x: 28, y: 38 }, { x: 150, y: 19.75 }] },
  { id: 'ae', source: 'a', target: 'e', waypoints: [{ x: 150, y: 19.75 }, { x: 522.5, y: 42.5 }] }
 ] };
function element() { return { value: '', textContent: '', dataset: {}, events: {}, children: [],
 addEventListener(k, f) { this.events[k] = f; }, append(v) { this.children.push(v); },
 replaceChildren() { this.children = []; } }; }
const ids = Object.fromEntries(['bpmn-data','bpmn-cy','bpmn-model-json','bpmn-status','bpmn-node-id','bpmn-node-label','bpmn-node-x','bpmn-node-y','bpmn-apply-node','bpmn-node-hint','bpmn-delete-element','bpmn-flow-source','bpmn-flow-target','bpmn-add-flow','bpmn-save-form'].map(id => [id, element()]));
ids['bpmn-data'].textContent = JSON.stringify(model); ids['bpmn-data'].dataset.editable = 'true';
const handlers = new Map(), graph = new Map();
let initialElements;
function add(elements) { for (const el of elements) graph.set(el.data.id, { record: el, id() { return el.data.id; }, data(value) { if (value) Object.assign(el.data,value); return el.data; }, position(value) { if (value) el.position=value; return el.position; }, select() {} }); }
const cy = { on(event, kind, fn) { handlers.set(event+':'+kind,fn); }, getElementById(id) { return graph.get(id); },
 pan() { return { x:0, y:0 }; }, zoom() { return 1; }, fit() {}, batch(fn) { fn(); },
 elements() { return { remove() { graph.clear(); } }; }, add };
const window = { cytoscape(options) { initialElements=options.elements; add(options.elements); return cy; } };
const document = { documentElement: { dataset: {} }, getElementById(id) { return ids[id] || null; },
 createElement() { return element(); }, querySelectorAll() { return []; },
 addEventListener(event, fn) { if(event==='DOMContentLoaded') this.ready=fn; } };
vm.runInNewContext(source, { window, document, localStorage: { getItem() { return null; } }, getComputedStyle() { return { getPropertyValue() { return ''; } }; }, crypto, setTimeout, clearTimeout, AbortController, console }, { filename: sourcePath, timeout:2000 });
document.ready();
const actual = id => JSON.parse(JSON.stringify(graph.get(id).record));
assert.deepEqual(actual('s').position, { x:28, y:38 });
assert.deepEqual(actual('a').position, { x:150, y:19.75 });
assert.equal(actual('a').data.width,100); assert.equal(actual('a').data.height,80);
assert.deepEqual(actual('e').position, { x:522.5, y:42.5 });
// Actual drag handler must subtract the imported half-width/height.
graph.get('a').position({ x:210.25, y:80.5 });
handlers.get('dragfree:node')({ target: graph.get('a') });
let snapshot=window.piBpmnSnapshot();
let a=snapshot.model.nodes.find(n=>n.id==='a');
assert.equal(a.x,160.25); assert.equal(a.y,40.5);
assert.deepEqual(JSON.parse(JSON.stringify(a.dimensions)), { width:100, height:80 });
let incoming=snapshot.model.flows.find(f=>f.id==='sa');
let outgoing=snapshot.model.flows.find(f=>f.id==='ae');
assert.deepEqual(JSON.parse(JSON.stringify(incoming.waypoints)), [{ x:28,y:38 },{ x:210.25,y:80.5 }]);
assert.deepEqual(JSON.parse(JSON.stringify(outgoing.waypoints)), [{ x:210.25,y:80.5 },{ x:522.5,y:42.5 }]);
// Explicit position edit must use the same imported geometry.
ids['bpmn-node-label'].value='Changed'; ids['bpmn-node-x'].value='-50.25'; ids['bpmn-node-y'].value='125.5';
ids['bpmn-apply-node'].events.click();
assert.deepEqual(actual('a').position, { x:-0.25, y:165.5 });
snapshot=window.piBpmnSnapshot(); a=snapshot.model.nodes.find(n=>n.id==='a');
assert.equal(a.label,'Changed'); assert.equal(a.x,-50.25); assert.equal(a.y,125.5);
assert.deepEqual(JSON.parse(JSON.stringify(a.dimensions)), { width:100, height:80 });
// New flow endpoints use actual centers for custom and default dimensions.
ids['bpmn-flow-source'].value='a'; ids['bpmn-flow-target'].value='e';
ids['bpmn-add-flow'].events.click();
snapshot=window.piBpmnSnapshot();
const added=snapshot.model.flows.find(f=>f.id!=='sa'&&f.id!=='ae');
assert.deepEqual(JSON.parse(JSON.stringify(added.waypoints)), [{ x:-0.25,y:165.5 },{ x:522.5,y:42.5 }]);
const posted=JSON.parse(ids['bpmn-model-json'].value);
assert.deepEqual(posted.nodes.find(n=>n.id==='a').dimensions,{width:100,height:80});
assert.equal(posted.nodes.find(n=>n.id==='e').dimensions,undefined);
console.log(JSON.stringify({ status:'PASS_ACTUAL_SCRIPT_FINITE_VM_GEOMETRY', cases:['render_custom_and_legacy_defaults','drag_with_imported_half_sizes_and_waypoints','position_edit_retains_dimensions','new_flow_centers_and_serialized_payload'], actual_script_sha256:crypto.createHash('sha256').update(source).digest('hex'), limits:'Controlled DOM/Cytoscape surfaces; no real browser, auth, persistence or restart claim' }));
