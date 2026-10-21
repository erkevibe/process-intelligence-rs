/* Server validates and stores every edit. No browser mining or authorization. */
(() => {
  'use strict';
  const byId = id => document.getElementById(id);
  const css = key => getComputedStyle(document.documentElement).getPropertyValue(key).trim();
  const sizes = node => node.dimensions || (node.kind === 'task' ? { width: 120, height: 70 } : { width: 45, height: 45 });
  const displayLabel = node => { const symbol = node.kind === 'exclusive_gateway' ? '×' : node.kind === 'parallel_gateway' ? '+' : ''; return symbol ? symbol + (node.label ? '\n' + node.label : '') : node.label; };
  let cy = null;
  let model = null;
  let selected = null;
  let selectedFlow = null;
  let editable = false;
  const status = message => { const node = byId('bpmn-status'); if (node) node.textContent = message; };
  const syncField = () => { const field = byId('bpmn-model-json'); if (field && model) field.value = JSON.stringify(model); };
  function styles() {
    return [
      { selector: 'node', style: { 'label': 'data(displayLabel)', 'width': 'data(width)', 'height': 'data(height)', 'background-color': css('--node'), 'border-color': css('--accent'), 'border-width': 2, 'color': css('--text'), 'font-family': 'Segoe UI, sans-serif', 'font-size': 12, 'text-valign': 'center', 'text-halign': 'center', 'text-wrap': 'wrap', 'text-max-width': 105 } },
      { selector: 'node[kind = "task"]', style: { 'shape': 'round-rectangle' } },
      { selector: 'node[kind = "start"], node[kind = "end"]', style: { 'shape': 'ellipse', 'text-valign': 'bottom', 'text-margin-y': 8, 'text-max-width': 100 } },
      { selector: 'node[kind = "end"]', style: { 'border-width': 4 } },
      { selector: 'node[kind = "exclusive_gateway"], node[kind = "parallel_gateway"]', style: { 'shape': 'diamond', 'font-size': 19 } },
      { selector: 'node[kind = "exclusive_gateway"][hasLabel = true], node[kind = "parallel_gateway"][hasLabel = true]', style: { 'text-valign': 'bottom', 'text-margin-y': 8, 'font-size': 12 } },
      { selector: 'edge', style: { 'label': 'data(label)', 'color': css('--text'), 'font-family': 'Segoe UI, sans-serif', 'font-size': 12, 'text-wrap': 'wrap', 'text-max-width': 160, 'text-background-color': css('--node'), 'text-background-opacity': 0.9, 'text-background-padding': 3, 'curve-style': 'bezier', 'width': 1.8, 'line-color': css('--edge'), 'target-arrow-color': css('--edge'), 'target-arrow-shape': 'triangle' } },
      { selector: 'edge[hasBends]', style: { 'curve-style': 'segments', 'segment-weights': 'data(weights)', 'segment-distances': 'data(distances)' } },
      { selector: ':selected', style: { 'border-color': css('--green'), 'line-color': css('--green'), 'target-arrow-color': css('--green'), 'border-width': 3 } }
    ];
  }
  function diagramElements() {
    const nodes = model.nodes.map(node => {
      const size = sizes(node);
      return { group: 'nodes', data: { ...node, ...size, displayLabel: displayLabel(node), hasLabel: Boolean(node.label) }, position: { x: node.x + size.width / 2, y: node.y + size.height / 2 }, grabbable: editable };
    });
    const centers = new Map(nodes.map(node => [node.data.id, node.position]));
    const edges = model.flows.map(flow => {
      const data = { id: flow.id, source: flow.source, target: flow.target, label: flow.label || '' };
      const from = centers.get(flow.source); const to = centers.get(flow.target);
      if (from && to && flow.waypoints.length > 2) {
        const dx = to.x - from.x; const dy = to.y - from.y; const length = Math.hypot(dx, dy);
        if (length > 0) {
          data.hasBends = true;
          data.weights = flow.waypoints.slice(1, -1).map(point => ((point.x - from.x) * dx + (point.y - from.y) * dy) / (length * length));
          data.distances = flow.waypoints.slice(1, -1).map(point => (dx * (point.y - from.y) - dy * (point.x - from.x)) / length);
        }
      }
      return { group: 'edges', data };
    });
    return [...nodes, ...edges];
  }
  function selectNode(nodeId) {
    selectedFlow = null;
    selected = model.nodes.find(node => node.id === nodeId) || null;
    if (!selected) return;
    const fields = { 'bpmn-node-id': selected.id, 'bpmn-node-label': selected.label, 'bpmn-node-x': selected.x, 'bpmn-node-y': selected.y };
    for (const [id, value] of Object.entries(fields)) { const field = byId(id); if (field) { field.value = value; field.disabled = !editable; } }
    const apply = byId('bpmn-apply-node'); if (apply) apply.disabled = !editable;
    const remove = byId('bpmn-delete-element'); if (remove) remove.disabled = !editable || selected.kind !== 'task';
    const hint = byId('bpmn-node-hint'); if (hint) hint.textContent = editable ? 'Измените подпись или положение, затем сохраните модель.' : 'Можно просматривать модель; изменение доступно редактору проекта.';
  }
  function selectFlow(flowId) {
    selected = null;
    selectedFlow = model.flows.find(flow => flow.id === flowId) || null;
    for (const id of ['bpmn-node-id', 'bpmn-node-label', 'bpmn-node-x', 'bpmn-node-y']) {
      const field = byId(id); if (field) { field.value = id === 'bpmn-node-id' ? (selectedFlow?.id ?? '') : id === 'bpmn-node-label' ? (selectedFlow?.label ?? '') : ''; field.disabled = id !== 'bpmn-node-label' || !editable || !selectedFlow; }
    }
    const apply = byId('bpmn-apply-node'); if (apply) apply.disabled = !editable || !selectedFlow;
    const remove = byId('bpmn-delete-element'); if (remove) remove.disabled = !editable || !selectedFlow;
    const hint = byId('bpmn-node-hint'); if (hint) hint.textContent = selectedFlow ? (editable ? 'Измените подпись перехода, затем сохраните модель. Подпись не является условием.' : 'Подпись перехода доступна для просмотра; изменение доступно редактору проекта.') : 'Выберите узел или переход на диаграмме.';
  }
  function applySelected() {
    if (!editable) return true;
    if (selectedFlow) {
      const label = byId('bpmn-node-label')?.value ?? selectedFlow.label ?? '';
      if (label) selectedFlow.label = label; else delete selectedFlow.label;
      cy.getElementById(selectedFlow.id).data({ label }); syncField();
      return true;
    }
    if (!selected) return true;
    const label = byId('bpmn-node-label')?.value ?? selected.label;
    const rawX = byId('bpmn-node-x')?.value ?? ''; const rawY = byId('bpmn-node-y')?.value ?? '';
    const x = Number(rawX); const y = Number(rawY);
    if (!rawX.trim() || !rawY.trim() || !Number.isFinite(x) || !Number.isFinite(y) || Math.abs(x) > 1000000 || Math.abs(y) > 1000000) { status('Положение должно быть числом от −1 000 000 до 1 000 000.'); return false; }
    selected.label = label; moveNode(selected, x, y);
    const size = sizes(selected); const node = cy.getElementById(selected.id);
    node.data({ displayLabel: displayLabel(selected), hasLabel: Boolean(label) });
    node.position({ x: x + size.width / 2, y: y + size.height / 2 }); syncField();
    return true;
  }
  function refillFlowChoices() {
    for (const id of ['bpmn-flow-source', 'bpmn-flow-target']) {
      const field = byId(id); if (!field) continue;
      const previous = field.value; field.replaceChildren();
      const empty = document.createElement('option'); empty.value = ''; empty.textContent = 'Выберите узел'; field.append(empty);
      for (const node of model.nodes) {
        if (id === 'bpmn-flow-source' && node.kind === 'end' || id === 'bpmn-flow-target' && node.kind === 'start') continue;
        const option = document.createElement('option'); option.value = node.id; option.textContent = (node.label || node.kind) + ' · ' + node.id; field.append(option);
      }
      field.value = previous;
    }
  }
  function redraw() {
    const pan = cy.pan(); const zoom = cy.zoom();
    cy.batch(() => { cy.elements().remove(); cy.add(diagramElements()); });
    cy.zoom(zoom); cy.pan(pan); refillFlowChoices(); syncField();
  }
  function center(node) { const size = sizes(node); return { x: node.x + size.width / 2, y: node.y + size.height / 2 }; }
  function moveNode(node, x, y) {
    const dx = x - node.x; const dy = y - node.y;
    for (const flow of model.flows) {
      if (!flow.waypoints.length) continue;
      if (flow.source === node.id) { flow.waypoints[0].x += dx; flow.waypoints[0].y += dy; }
      if (flow.target === node.id) { const last = flow.waypoints[flow.waypoints.length - 1]; last.x += dx; last.y += dy; }
    }
    node.x = x; node.y = y;
    for (const element of diagramElements()) { if (element.group === 'edges') cy.getElementById(element.data.id).data(element.data); }
  }
  function initDiagram() {
    const payload = byId('bpmn-data'); const container = byId('bpmn-cy');
    if (!payload || !container || !window.cytoscape) return;
    try { model = JSON.parse(payload.textContent); } catch { status('Не удалось открыть модель. Перезагрузите страницу.'); return; }
    if (!model || !Array.isArray(model.nodes) || !Array.isArray(model.flows)) { status('Не удалось прочитать модель.'); return; }
    editable = payload.dataset.editable === 'true';
    cy = window.cytoscape({ container, elements: diagramElements(), style: styles(), layout: { name: 'preset', fit: true, padding: 45 }, minZoom: 0.08, maxZoom: 4, wheelSensitivity: 0.16, selectionType: 'single', boxSelectionEnabled: false });
    cy.on('tap', 'node', event => selectNode(event.target.id()));
    cy.on('tap', 'edge', event => selectFlow(event.target.id()));
    cy.on('dragfree', 'node', event => {
      if (!editable) return;
      const node = model.nodes.find(item => item.id === event.target.id()); if (!node) return;
      const position = event.target.position(); const size = sizes(node);
      moveNode(node, Math.round((position.x - size.width / 2) * 1000) / 1000, Math.round((position.y - size.height / 2) * 1000) / 1000);
      syncField(); selectNode(node.id); status('Положение изменено в черновике. Сохраните модель.');
    });
    byId('bpmn-fit')?.addEventListener('click', () => cy.fit(undefined, 45));
    byId('bpmn-apply-node')?.addEventListener('click', () => {
      if (applySelected()) { refillFlowChoices(); status('Черновик изменён. Сохраните модель, чтобы применить изменения.'); }
    });
    byId('bpmn-add-task')?.addEventListener('click', () => {
      if (!editable || !applySelected()) return;
      if (model.nodes.length >= 1000) { status('Достигнут предел: 1000 узлов.'); return; }
      const extent = cy.extent(); const x = Math.round((extent.x1 + extent.x2) / 2 - 60); const y = Math.round((extent.y1 + extent.y2) / 2 - 35);
      const node = { id: 'task_' + crypto.randomUUID(), kind: 'task', label: byId('bpmn-new-task-label')?.value.trim() || 'Новое действие', x: Math.max(-1000000, Math.min(1000000, x)), y: Math.max(-1000000, Math.min(1000000, y)) };
      model.nodes.push(node); redraw(); cy.getElementById(node.id).select(); selectNode(node.id); status('Задача добавлена в черновик. Соедините её входящим и исходящим переходами перед сохранением.');
    });
    byId('bpmn-add-flow')?.addEventListener('click', () => {
      if (!editable || !applySelected()) return;
      if (model.flows.length >= 4000) { status('Достигнут предел: 4000 переходов.'); return; }
      const source = model.nodes.find(node => node.id === byId('bpmn-flow-source')?.value); const target = model.nodes.find(node => node.id === byId('bpmn-flow-target')?.value);
      if (!source || !target || source.kind === 'end' || target.kind === 'start') { status('Выберите начало и конец перехода.'); return; }
      const flow = { id: 'flow_' + crypto.randomUUID(), source: source.id, target: target.id, waypoints: [center(source), center(target)] };
      model.flows.push(flow); redraw(); cy.getElementById(flow.id).select(); selectFlow(flow.id); status('Переход добавлен в черновик. Сохраните модель.');
    });
    byId('bpmn-delete-element')?.addEventListener('click', () => {
      if (!editable) return;
      if (selected?.kind === 'task') {
        model.flows = model.flows.filter(flow => flow.source !== selected.id && flow.target !== selected.id);
        model.nodes = model.nodes.filter(node => node.id !== selected.id);
      } else if (selectedFlow) { model.flows = model.flows.filter(flow => flow.id !== selectedFlow.id); }
      else return;
      selectFlow(null); redraw(); status('Выбранное удалено из черновика. Проверьте путь от начала к концу и сохраните модель.');
    });
    byId('bpmn-save-form')?.addEventListener('submit', event => { if (!applySelected()) event.preventDefault(); else { syncField(); status('Отправляем черновик. Дождитесь подтверждения после обновления страницы.'); } });
    refillFlowChoices();
    syncField();
    window.piBpmnSnapshot = () => ({ model: JSON.parse(JSON.stringify(model)), selected_node_id: selected?.id ?? null, selected_flow_id: selectedFlow?.id ?? null, pan: cy.pan(), zoom: cy.zoom(), editable });
  }
  function initActivityPicker(picker) {
    const field = picker.dataset.field;
    const hidden = picker.querySelector('input[type="hidden"]');
    const search = picker.querySelector('[data-activity-search]');
    const options = picker.querySelector('[data-activity-options]');
    const chips = picker.querySelector('[data-activity-selected]');
    const message = picker.querySelector('[data-activity-status]');
    if (!['retain', 'remove'].includes(field) || !hidden || !search || !options || !chips || !message) return;
    let values;
    try { values = JSON.parse(hidden.value); } catch { message.textContent = 'Не удалось прочитать выбор. Перезагрузите страницу.'; return; }
    if (!Array.isArray(values) || values.some(value => typeof value !== 'string')) return;
    const selectedValues = new Set(values);
    let request = null;
    let requestVersion = 0;
    let timer = null;
    const source = new URL(picker.dataset.source, location.href);
    if (source.origin !== location.origin || !/^\/logs\/[^/]+\/activities$/.test(source.pathname)) { message.textContent = 'Не удалось найти список действий.'; return; }
    function synchronize() {
      hidden.value = JSON.stringify([...selectedValues]);
      for (const checkbox of options.querySelectorAll('input[type="checkbox"]')) checkbox.checked = selectedValues.has(checkbox.value);
      chips.replaceChildren();
      if (!selectedValues.size) { const empty = document.createElement('span'); empty.className = 'platform-note'; empty.textContent = 'Ничего не выбрано'; chips.append(empty); return; }
      let count = 0;
      for (const value of selectedValues) {
        if (count++ >= 50) break;
        const button = document.createElement('button'); button.type = 'button'; button.className = 'activity-chip'; button.title = value;
        const caption = document.createElement('span'); caption.textContent = value;
        const close = document.createElement('span'); close.textContent = ' ×'; close.setAttribute('aria-hidden', 'true');
        button.append(caption, close); button.setAttribute('aria-label', 'Убрать из выбора: ' + value);
        button.addEventListener('click', () => { selectedValues.delete(value); synchronize(); }); chips.append(button);
      }
      if (selectedValues.size > 50) { const remaining = document.createElement('span'); remaining.className = 'platform-note'; remaining.textContent = 'Выбрано ' + selectedValues.size + ' действий. Здесь показаны первые 50; остальные можно найти поиском.'; chips.append(remaining); }
    }
    async function loadOptions() {
      const version = ++requestVersion;
      if (request) request.abort();
      request = new AbortController();
      const endpoint = new URL(source); endpoint.searchParams.set('q', search.value);
      message.textContent = 'Поиск…';
      try {
        const response = await fetch(endpoint, { method: 'GET', credentials: 'same-origin', mode: 'same-origin', headers: { Accept: 'application/json' }, signal: request.signal });
        if (!response.ok) throw new Error('activity_request');
        const payload = await response.json();
        if (version !== requestVersion) return;
        if (!Array.isArray(payload.activities) || payload.activities.length > 50 || payload.activities.some(value => typeof value !== 'string')) throw new Error('activity_response');
        options.replaceChildren();
        for (const value of payload.activities) {
          const label = document.createElement('label'); label.className = 'activity-option';
          const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.value = value; checkbox.checked = selectedValues.has(value);
          const text = document.createElement('span'); text.textContent = value;
          checkbox.addEventListener('change', () => { if (checkbox.checked) selectedValues.add(value); else selectedValues.delete(value); synchronize(); });
          label.append(checkbox, text); options.append(label);
        }
        if (!payload.activities.length) { const empty = document.createElement('span'); empty.className = 'platform-note'; empty.textContent = 'Действия не найдены'; options.append(empty); }
        message.textContent = payload.has_more ? 'Показаны первые 50 совпадений. Уточните поиск. Выбранные действия сохраняются.' : 'Выбор сохраняется при поиске. Изменения применятся после нажатия «Применить фильтр».';
        synchronize();
      } catch (error) {
        if (version !== requestVersion || error.name === 'AbortError') return;
        message.textContent = 'Не удалось загрузить действия. Повторите поиск. Ваш выбор сохранён.';
      }
    }
    search.addEventListener('input', () => { clearTimeout(timer); if (request) request.abort(); requestVersion++; timer = setTimeout(loadOptions, 200); });
    picker.querySelector('[data-activity-clear]')?.addEventListener('click', () => { selectedValues.clear(); synchronize(); });
    synchronize(); loadOptions();
  }
  document.addEventListener('DOMContentLoaded', () => {
    const savedTheme = localStorage.getItem('pi-theme'); if (savedTheme === 'light' || savedTheme === 'dark') document.documentElement.dataset.theme = savedTheme;
    byId('platform-theme')?.addEventListener('click', () => { const theme = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light'; document.documentElement.dataset.theme = theme; localStorage.setItem('pi-theme', theme); if (cy) cy.style(styles()); });
    initDiagram();
    document.querySelectorAll('.activity-picker').forEach(initActivityPicker);
  });
})();
