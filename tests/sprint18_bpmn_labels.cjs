// Finite actual-script regression on controlled DOM/Cytoscape surfaces.
// Real browser, authorization, PostgreSQL and restart are separate acceptance gates.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const source = fs.readFileSync('static/platform.js', 'utf8');

function surface(editable) {
  function field() { return { value: '', textContent: '', dataset: {}, events: {}, children: [], addEventListener(event, fn) { this.events[event] = fn; }, append(child) { this.children.push(child); }, replaceChildren() { this.children = []; } }; }
  const ids = Object.fromEntries(['bpmn-data', 'bpmn-cy', 'bpmn-model-json', 'bpmn-status', 'bpmn-node-id', 'bpmn-node-label', 'bpmn-node-x', 'bpmn-node-y', 'bpmn-apply-node', 'bpmn-node-hint', 'bpmn-delete-element', 'bpmn-flow-source', 'bpmn-flow-target', 'bpmn-add-flow', 'bpmn-save-form'].map(id => [id, field()]));
  const model = { schema_version: 1, process_id: 'p', name: 'M', discovery: null, nodes: [
    { id: 's', kind: 'start', label: '', x: 0, y: 0 },
    { id: 'a', kind: 'task', label: 'A', x: 100, y: 20, dimensions: { width: 100, height: 80 } },
    { id: 'e', kind: 'end', label: '', x: 400, y: 0 }
  ], flows: [
    { id: 'sa', source: 's', target: 'a', label: '  Ә <yes> & "go"  ', waypoints: [{ x: 22.5, y: 22.5 }, { x: 150, y: 60 }] },
    { id: 'ae', source: 'a', target: 'e', waypoints: [] }
  ] };
  ids['bpmn-data'].textContent = JSON.stringify(model);
  ids['bpmn-data'].dataset.editable = String(editable);
  const handlers = new Map(), graph = new Map();
  let options;
  function add(elements) { for (const element of elements) graph.set(element.data.id, { record: element, id() { return element.data.id; }, data(value) { if (value) Object.assign(element.data, value); return element.data; }, position(value) { if (value) element.position = value; return element.position; }, select() {} }); }
  const cy = { on(event, kind, fn) { handlers.set(`${event}:${kind}`, fn); }, getElementById(id) { return graph.get(id); }, pan() { return { x: 0, y: 0 }; }, zoom() { return 1; }, fit() {}, batch(fn) { fn(); }, elements() { return { remove() { graph.clear(); } }; }, add };
  const window = { cytoscape(config) { options = config; add(config.elements); return cy; } };
  const document = { documentElement: { dataset: {} }, getElementById(id) { return ids[id] || null; }, createElement: field, querySelectorAll() { return []; }, addEventListener(event, fn) { if (event === 'DOMContentLoaded') this.ready = fn; } };
  vm.runInNewContext(source, { window, document, localStorage: { getItem() { return null; } }, getComputedStyle() { return { getPropertyValue() { return ''; } }; }, crypto, setTimeout, clearTimeout, AbortController, console }, { filename: 'static/platform.js', timeout: 2000 });
  document.ready();
  return { ids, graph, options, window, tap(kind, id) { handlers.get(`tap:${kind}`)({ target: graph.get(id) }); }, snapshot() { return JSON.parse(JSON.stringify(window.piBpmnSnapshot())); } };
}

const editor = surface(true);
assert.equal(editor.options.style.find(style => style.selector === 'edge').style.label, 'data(label)');
assert.equal(editor.graph.get('sa').data().label, '  Ә <yes> & "go"  ');
assert.equal(editor.graph.get('ae').data().label, '');
const before = editor.snapshot().model;
editor.tap('edge', 'sa');
assert.equal(editor.snapshot().selected_flow_id, 'sa');
assert.equal(editor.snapshot().selected_node_id, null);
assert.equal(editor.ids['bpmn-node-label'].value, before.flows[0].label);
assert.equal(editor.ids['bpmn-node-label'].disabled, false);
assert.equal(editor.ids['bpmn-node-x'].disabled, true);
assert.equal(editor.ids['bpmn-node-y'].disabled, true);
assert.equal(editor.ids['bpmn-apply-node'].disabled, false);
const label = '  Жаңа <choice> & "two"\n\t  ';
editor.ids['bpmn-node-label'].value = label;
editor.ids['bpmn-apply-node'].events.click();
assert.equal(editor.graph.get('sa').data().label, label);
let after = editor.snapshot().model;
assert.equal(after.flows[0].label, label);
assert.deepEqual(after.flows[0].waypoints, before.flows[0].waypoints);
assert.deepEqual(after.nodes, before.nodes);
editor.tap('node', 'a');
editor.ids['bpmn-node-label'].value = 'Edited task';
editor.ids['bpmn-node-x'].value = '123.5'; editor.ids['bpmn-node-y'].value = '234.25';
editor.ids['bpmn-apply-node'].events.click();
assert.equal(editor.snapshot().model.flows[0].label, label);
editor.tap('edge', 'sa');
editor.ids['bpmn-node-label'].value = 'save directly';
editor.ids['bpmn-save-form'].events.submit({ preventDefault() { assert.fail('valid flow save prevented'); } });
assert.equal(JSON.parse(editor.ids['bpmn-model-json'].value).flows[0].label, 'save directly');
editor.ids['bpmn-node-label'].value = '';
editor.ids['bpmn-apply-node'].events.click();
assert.equal(editor.snapshot().model.flows[0].label, undefined);
assert.equal(editor.graph.get('sa').data().label, '');
editor.tap('edge', 'ae');
assert.equal(editor.ids['bpmn-node-label'].value, '');

const viewer = surface(false);
viewer.tap('edge', 'sa');
assert.equal(viewer.ids['bpmn-node-label'].value, before.flows[0].label);
assert.equal(viewer.ids['bpmn-node-label'].disabled, true);
assert.equal(viewer.ids['bpmn-apply-node'].disabled, true);
assert.equal(viewer.ids['bpmn-delete-element'].disabled, true);
viewer.ids['bpmn-node-label'].value = 'forged local edit';
viewer.ids['bpmn-apply-node'].events.click();
assert.equal(viewer.snapshot().model.flows[0].label, before.flows[0].label);
console.log(JSON.stringify({ status: 'PASS_FINITE_ACTUAL_SCRIPT_FLOW_LABELS', actual_script_sha256: crypto.createHash('sha256').update(source).digest('hex'), cases: ['edge_display_and_selection', 'editor_apply_and_save', 'label_edit_preserves_geometry', 'node_edit_retains_flow_label', 'empty_label_omission', 'historical_flow_without_label', 'viewer_controls_and_handler_guard'], limitation: 'Controlled surfaces; no real browser/auth/persistence/restart acceptance' }));
