# UI contract R1

Owner: /root/pm (UI author, not QA). Files: static/, templates/, this contract. Rust endpoints and rendering: /root.

## Full HTML and CSP

Use templates/shell.html and replace {{NONCE}}, {{ANALYSIS_PANEL}}, {{ERROR_PANEL}}. Templates/analysis-panel.html is an exact reference for renderer hooks/classes. Empty analysis: `<section id="analysis-panel"><div class="card placeholder-card"><h2>Результаты без догадок</h2><p>Загрузите журнал, чтобы увидеть число трасс, событий и действий, частоты переходов и варианты.</p></div></section>`.

CSP response header: `default-src 'self'; script-src 'self' 'nonce-{random}'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`. Cytoscape needs inline styles on its canvas containers; unsafe-inline applies only to style-src. Never unsafe-eval. `html data-nonce` must match this full response's cryptographic nonce. Datastar v1.0.4 is locally bundled and supports nonce mode. Dynamic server responses do not embed user strings in executable expressions.

POST /logs normal multipart form upload, field name `file`, responds with full page and a new nonce. Errors retain previous analysis panel. File chooser client check supplements, never replaces, server admission limits.

## View and selection

POST /logs/{generated_id}/view receives application/x-www-form-urlencoded field threshold. Threshold static expression is window.piQueueView(evt.target). Stable bridge invokes Datastar @post with form serialization, requestCancellation:disabled and retry:never. No user content in expressions. Server returns SSE `datastar-patch-elements` with one analysis-panel outer morph. All lines of multiline HTML must use `data: elements ` prefix, end event with two newlines. Keep graph-card/island outside analysis-panel.

Selection and threshold use one stable hidden mutation-form outside analysis-panel. Adapter snapshots endpoint and form values, dispatches only one mutation at a time, and waits for Datastar's returned Promise before launching the next. Adjacent pending threshold changes coalesce; selection ordering is retained. Form fields are threshold, kind (node/edge), and id (generated graph identifier). Root validates identifiers and returns the updated analysis panel. No independent fetch or SSE parser is used. This prevents older selection/view responses from overwriting newer panel HTML.

## Graph payload

Inside each analysis-panel: `<div id="graph-data" hidden data-ignore>{HTML escaped JSON}</div>`. This is inert text, not a script. Payload:

```json
{"log_id":"generated-log-id","analysis_version":1,"view_revision":2,"min_edge_frequency":1,"nodes":[{"id":"n0","label":"A","count":5,"start_count":4,"end_count":1}],"edges":[{"id":"e0","source":"n0","target":"n0","count":1}],"selected_id":null}
```

selected_id is null or a generated graph element ID. Always send it: null explicitly clears selection. Adapter also accepts selection {kind,id} for future use. analysis_version and view_revision are monotonic safe integers in R1. Adapter rejects graph payloads older than its last accepted versions, updates existing elements, preserves node positions/pan/zoom for the same log, fits only after a new log. All activities remain server graph nodes regardless of threshold. Hidden selected edges disappear and selection clears. Graph labels use Cytoscape data rendering, not HTML.

`GET /logs/{id}/graph?threshold=k` is optional for diagnostics; adapter consumes embedded graph JSON and does not need this fetch. Server owns filtering and counts. No browser mining, no own SSE parser, no SPA/router.

## Rendering classes

Stats: .stats-grid/.stat/.stat-label/.stat-value. Variants: .variant-list with .variant-row, .variant-path (escaped activity sequence), .variant-count. Avoid dynamic inline width calculations for bars; textual counts suffice. Details: .selection-details/.detail-row. Error: .alert with role=alert and escaped stable message/code. JSON export link /logs/id/export.

## Verification status

Pinned bundles downloaded from official tagged repositories; SHA256 and license files in static/vendor-manifest.json. `node --check static/app.js` passed. CSP/SSE browser integration requires running Rust server and independent QA; no browser PASS claimed at this handoff.

## Queue refinement

The graph version guard alone does not protect panel HTML. A unified request queue now serializes both endpoint families through a stable Datastar bridge. The bridge fields never change while its request is in flight, even when panel morph removes old inputs. piRunMutation catches rejected requests and releases the queue. No cancellable before-patch hook was found in the pinned Datastar API; no unsupported hooks were added. Browser verification remains pending.


