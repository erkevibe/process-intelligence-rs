/* A small graph island adapter. Mining and filtering remain on the server. */
(() => {
  'use strict';
  let cy = null;
  let accepted = { analysis: -1, revision: -1, log: null };
  let lastPayload = '';
  let acceptedPanel = null;
  let updateQueued = false;
  let isUpdating = false;
  let selectedCase = null;
  const mutations = [];
  let mutationInFlight = false;
  const byId = id => document.getElementById(id);
  const status = message => { const node = byId('connection-status'); if (node) node.textContent = message; };
  const css = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const graphStyle = () => [
    { selector: 'node', style: { 'background-color': css('--node'), 'border-color': css('--accent'), 'border-width': 1.5, 'shape': 'round-rectangle', 'width': 115, 'height': 55, 'label': 'data(displayLabel)', 'color': css('--text'), 'font-family': 'Segoe UI, sans-serif', 'font-size': 11, 'text-wrap': 'wrap', 'text-max-width': 100, 'text-valign': 'center', 'text-halign': 'center', 'text-outline-width': 0 } },
    { selector: 'edge', style: { 'width': 1.8, 'line-color': css('--edge'), 'target-arrow-color': css('--edge'), 'target-arrow-shape': 'triangle', 'curve-style': 'bezier', 'label': 'data(count)', 'color': css('--muted'), 'font-size': 10, 'text-background-color': css('--surface-2'), 'text-background-opacity': 1, 'text-background-padding': 3, 'text-rotation': 'autorotate', 'loop-direction': '-45deg', 'loop-sweep': '70deg' } },
    { selector: '.case-path', style: { 'border-color': css('--case'), 'border-width': 2.5, 'line-color': css('--case'), 'target-arrow-color': css('--case'), 'width': 2.6 } },
    { selector: 'node.case-path', style: { 'width': 115 } },
    { selector: ':selected', style: { 'border-color': css('--green'), 'border-width': 3, 'line-color': css('--green'), 'target-arrow-color': css('--green'), 'color': css('--green') } }
  ];
  function ensureGraph() {
    const container = byId('cy');
    if (!container || !window.cytoscape) return null;
    if (cy) return cy;
    cy = window.cytoscape({ container, elements: [], style: graphStyle(), layout: { name: 'preset' }, minZoom: 0.12, maxZoom: 4, wheelSensitivity: 0.18, boxSelectionEnabled: false, selectionType: 'single' });
    cy.on('tap', 'node, edge', event => {
      if (isUpdating) return;
      const item = event.target;
      sendSelection(item.isNode() ? 'node' : 'edge', item.id());
    });
    return cy;
  }
  function enqueueMutation(action, values) {
    const endpoint = new URL(action, location.href);
    if (endpoint.origin !== location.origin || !/^\/logs\/log-\d+\/(view|selection)$/.test(endpoint.pathname)) {
      status('Не удалось определить действие для текущего журнала.');
      return;
    }
    const item = { action: endpoint.pathname, values: { ...values } };
    const last = mutations[mutations.length - 1];
    // Coalesce only adjacent pending threshold changes. Selection ordering stays intact.
    if (last && last.action === item.action && item.action.endsWith('/view')) mutations[mutations.length - 1] = item;
    else mutations.push(item);
    dispatchMutation();
  }
  function dispatchMutation() {
    if (mutationInFlight || !mutations.length) return;
    const form = byId('mutation-form');
    const button = byId('mutation-submit');
    if (!form || !button) { status('Не удалось обновить анализ. Перезагрузите страницу.'); return; }
    const item = mutations.shift();
    form.action = item.action;
    for (const name of ['threshold', 'kind', 'id']) form.elements.namedItem(name).value = item.values[name] ?? '';
    mutationInFlight = true;
    button.click();
  }
  window.piRunMutation = async action => {
    try { await action(); }
    catch { status('Не удалось обновить анализ. Повторите действие.'); }
    finally { mutationInFlight = false; queueGraphUpdate(); dispatchMutation(); }
  };
  window.piQueueView = input => {
    const form = input.closest('form');
    if (form) enqueueMutation(form.action, { threshold: input.value });
  };
  window.piQueueCase = id => {
    const form = byId('threshold-form');
    if (!form || typeof id !== 'string' || !id.length) return;
    const endpoint = new URL(form.action, location.href);
    enqueueMutation(endpoint.pathname.replace(/\/view$/, '/selection'), { kind: 'case', id });
  };
  function sendSelection(kind, id) {
    const form = byId('threshold-form');
    if (!form) return;
    const endpoint = new URL(form.action, location.href);
    enqueueMutation(endpoint.pathname.replace(/\/view$/, '/selection'), { kind, id });
  }
  function syncGraph() {
    updateQueued = false;
    const payloadNode = byId('graph-data');
    if (!payloadNode) return;
    const payload = payloadNode.textContent.trim();
    if (!payload || payload === lastPayload) return;
    let graph;
    try { graph = JSON.parse(payload); } catch { status('Не удалось прочитать данные графа. Повторите анализ.'); return; }
    const analysis = Number(graph.analysis_version);
    const revision = Number(graph.view_revision);
    if (!Number.isSafeInteger(analysis) || !Number.isSafeInteger(revision) || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) { status('Неподдерживаемая версия данных графа.'); return; }
    const payloadLog = String(graph.log_id ?? analysis);
    const olderVersion = analysis < accepted.analysis || (analysis === accepted.analysis && revision < accepted.revision);
    const wrongLogForVersion = analysis === accepted.analysis && accepted.log !== null && payloadLog !== accepted.log;
    if (olderVersion || wrongLogForVersion) {
      // Protect server-rendered counts/details as well as the graph island.
      // Only clone an already accepted, escaped server DOM; no HTML/SSE parsing.
      const panel = byId('analysis-panel');
      if (panel && acceptedPanel) panel.replaceWith(acceptedPanel.cloneNode(true));
      return;
    }
    const instance = ensureGraph();
    if (!instance) { status('Граф пока недоступен: проверьте загрузку локальных файлов.'); return; }
    const newLog = accepted.log !== String(graph.log_id ?? analysis);
    const previousZoom = instance.zoom();
    const previousPan = { ...instance.pan() };
    const previousSelection = instance.$(':selected').map(element => element.id());
    const positions = new Map(instance.nodes().map(node => [node.id(), { ...node.position() }]));
    isUpdating = true;
    instance.startBatch();
    const wantedNodes = new Set(graph.nodes.map(node => String(node.id)));
    const wantedEdges = new Set(graph.edges.map(edge => String(edge.id)));
    instance.edges().filter(edge => !wantedEdges.has(edge.id())).remove();
    instance.nodes().filter(node => !wantedNodes.has(node.id())).remove();
    for (const node of graph.nodes) {
      const id = String(node.id);
      const label = String(node.label);
      const short = [...label].slice(0, 46).join('') + ([...label].length > 46 ? '…' : '');
      const data = { ...node, id, label, displayLabel: `${short}\n${node.count}` };
      const existing = instance.getElementById(id);
      if (existing.length) existing.data(data);
      else instance.add({ group: 'nodes', data, position: positions.get(id) });
    }
    for (const edge of graph.edges) {
      const data = { ...edge, id: String(edge.id), source: String(edge.source), target: String(edge.target) };
      const existing = instance.getElementById(data.id);
      if (existing.length) existing.data(data);
      else instance.add({ group: 'edges', data });
    }
    instance.elements().removeClass('case-path');
    const highlight = graph.case_highlight;
    for (const id of [...(Array.isArray(highlight?.node_ids) ? highlight.node_ids : []), ...(Array.isArray(highlight?.edge_ids) ? highlight.edge_ids : [])]) {
      instance.getElementById(String(id)).addClass('case-path');
    }
    selectedCase = graph.selected_case_id ?? null;
    const caseLegend = byId('case-legend');
    if (caseLegend) caseLegend.hidden = selectedCase === null;
    instance.elements().unselect();
    const serverSelection = graph.selection?.id ?? graph.selected_id;
    const selectedIds = graph.selection === null || graph.selected_id === null ? [] : serverSelection ? [String(serverSelection)] : previousSelection;
    for (const id of selectedIds) instance.getElementById(id).select();
    instance.endBatch();
    if (newLog && graph.nodes.length) instance.layout({ name: 'breadthfirst', directed: true, padding: 45, spacingFactor: 1.3, animate: false }).run();
    else { instance.zoom(previousZoom); instance.pan(previousPan); }
    isUpdating = false;
    accepted = { analysis, revision, log: String(graph.log_id ?? analysis) };
    lastPayload = payload;
    acceptedPanel = byId('analysis-panel')?.cloneNode(true) ?? null;
    const empty = byId('graph-empty');
    if (empty) empty.hidden = graph.nodes.length > 0;
    const summary = byId('graph-summary');
    if (summary) summary.textContent = `${graph.nodes.length} действий · ${graph.edges.length} переходов · k ≥ ${graph.min_edge_frequency}`;
    status('');
  }
  function queueGraphUpdate() { if (!updateQueued) { updateQueued = true; requestAnimationFrame(syncGraph); } }
  function initialize() {
    let storedTheme;
    try { storedTheme = localStorage.getItem('pi-theme'); } catch { /* Local storage is optional. */ }
    if (storedTheme === 'light' || storedTheme === 'dark') document.documentElement.dataset.theme = storedTheme;
    byId('theme-toggle')?.addEventListener('click', () => {
      const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      document.documentElement.dataset.theme = theme;
      try { localStorage.setItem('pi-theme', theme); } catch { /* Optional preference. */ }
      if (cy) cy.style(graphStyle());
    });
    byId('xes-file')?.addEventListener('change', event => {
      const file = event.target.files?.[0];
      if (byId('file-label')) byId('file-label').textContent = file ? file.name : 'Выберите XES-файл';
    });
    byId('background-mode')?.addEventListener('change', event => {
      const form = byId('upload-form');
      if (form) form.action = event.target.checked ? '/jobs' : '/logs';
    });
    byId('upload-form')?.addEventListener('submit', event => {
      const file = byId('xes-file')?.files?.[0];
      if (file && file.size > 20 * 1024 * 1024) { event.preventDefault(); status('Файл превышает 20 MiB. Выберите меньший журнал.'); return; }
      const button = event.target.querySelector('button[type=submit]');
      if (button) { button.disabled = true; button.textContent = 'Анализируем…'; }
    });
    byId('graph-fit')?.addEventListener('click', () => cy?.fit(undefined, 45));
    byId('graph-zoom-in')?.addEventListener('click', () => { if (cy) cy.zoom({ level: Math.min(cy.maxZoom(), cy.zoom() * 1.2), renderedPosition: { x: cy.width() / 2, y: cy.height() / 2 } }); });
    byId('graph-zoom-out')?.addEventListener('click', () => { if (cy) cy.zoom({ level: Math.max(cy.minZoom(), cy.zoom() / 1.2), renderedPosition: { x: cy.width() / 2, y: cy.height() / 2 } }); });
    new MutationObserver(queueGraphUpdate).observe(document.body, { childList: true, characterData: true, subtree: true });
    document.addEventListener('datastar-fetch', event => {
      if (event.detail?.type === 'error' || event.detail?.type === 'retries-failed') status('Не удалось обновить анализ. Проверьте соединение с локальным приложением.');
      else if (event.detail?.type === 'finished') queueGraphUpdate();
    });
    const container = byId('cy');
    if (container && window.ResizeObserver) new ResizeObserver(() => cy?.resize()).observe(container);
    ensureGraph();
    syncGraph();
  }
  // Read-only diagnostic snapshot; does not perform analysis or filtering.
  window.piGraphSnapshot = () => cy ? { ...accepted, pan: { ...cy.pan() }, zoom: cy.zoom(), nodes: cy.nodes().length, edges: cy.edges().length, selected: cy.$(':selected').map(element => element.id()), selected_case_id: selectedCase, highlighted: cy.$('.case-path').map(element => element.id()), panel_version: { analysis: Number(byId('analysis-panel')?.dataset.analysisVersion ?? -1), revision: Number(byId('analysis-panel')?.dataset.viewRevision ?? -1) } } : null;
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();



