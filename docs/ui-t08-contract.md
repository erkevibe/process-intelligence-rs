# T08 UI contract — optional after clean R1 baseline

Status: implementation contract agreed with root after independent AC11 and clean baseline. UI changes implemented; server integration and independent AC13/14 verification pending. Owner UI: PM; Rust jobs and case projection: root; independent QA: qa_process. This document does not widen R1 AC01–12. Begin only after AC11 measurement and a verified clean baseline; protect the last hour for delivery. If less than 60 minutes remains before that protected hour, move T08 to the next iteration.

## Reachable order and stop conditions

1. 10 minutes: freeze job/case data contracts and one controlled cooperative job fixture with QA.
2. 20 minutes: one job state panel, stage-only progress and cancellation request, terminal snapshot.
3. 15 minutes: selected case details plus server-supplied highlighted graph IDs.
4. 15 minutes: integrated independent checks; no additional animations or streaming percentages.

At 30 minutes, if job cancellation is not correct, defer case selection and use remaining time for job QA. If the parser cannot interrupt its current stage, report that limitation. A partial implementation never receives AC13/14 PASS.

## User-visible job states

One local worker: queued → running → completed | failed | cancelled. Actual admission bound: at most two accepted non-terminal jobs, one CPU worker, and eight retained terminal snapshots. A synchronous /logs import may occupy the worker, leaving both accepted jobs queued. Full queue returns a stable error, without replacing the last valid analysis. Running stages use real transitions: upload received, validating/parsing, calculating counts, preparing result. While upload is underway, the browser may show “Загружаем файл…”; it does not invent upload byte percentages.

Copy examples:

- queued: “Журнал ожидает обработки”.
- parsing: “Читаем и проверяем XES”.
- analyzing: “Считаем варианты и переходы”.
- cancel_requested: “Отмена запрошена. Ожидаем безопасную остановку”.
- non-interruptible parse: “Отмена запрошена. Разбор этого файла завершится перед остановкой”.
- cancelled: “Обработка отменена. Предыдущий анализ сохранён”.
- failed: stable code and plain Russian message, no exception details.

No fabricated percentage, countdown or successful-completion timer. Stage text is sufficient. Percentage is allowed only if server supplies measured processed and total counts from the actual job. A synthetic slow fixture verifies cancellation only; it is not presented as a speed benchmark.

## HTTP/SSE addition

Existing normal R1 POST /logs native multipart upload remains the default. Checkbox background-mode switches the same upload-form action to /jobs; it does not add a second submit button. Optional POST /jobs accepts the same single-file multipart contract and admission limits, returns 202 full HTML navigation with a new page nonce and root-rendered #job-panel. This agreed refinement replaces the original upload-patch proposal. Server first acquires a bounded slot; server-side parsing/mining never blocks the HTTP executor.

The generated stable hidden #job-connection is outside morphed #job-panel. It must not use data-ignore on the initializer: Datastar would ignore data-init as well. Its placement alone protects it from job-panel morph. Its static data-init expression calls @get(el.dataset.eventsUrl, {openWhenHidden:true}) with a root-generated data-events-url. Keeping the initializer outside morph prevents the first progress patch from destroying its stream cleanup scope. Endpoint is GET /jobs/{id}/events; GET /jobs/{id} exposes the authoritative JSON snapshot for independent checks. Datastar handles SSE; no custom EventSource/parser. One stream per current job, heartbeats from server, initial snapshot on every subscription/reconnect, monotonically increasing job_revision. If a page reloads, server GET / returns the current job snapshot or explicitly says no active job; it does not invent recovery after server restart.

SSE patches #job-panel for progress. On completed, server patches #analysis-panel with the new analysis_version then sends the terminal job panel. Graph island remains outside both. Terminal job panel has no data-init; the stable connection remains outside its morph and the finite server stream closes on the terminal snapshot. A transport failure displays “Связь с обработкой прервана; проверяем состояние”, never success. Server ignores stale job_revision; reconnection presents the actual current snapshot.

POST /jobs/{id}/cancel is idempotent. With Datastar SSE Accept it returns 204 and does not patch HTML; the watch stream alone owns job-panel. Direct API calls receive a JSON snapshot. This prevents a late cancel response from overwriting a newer terminal state. Cancel button uses stable Datastar form/action with generated endpoint, outside the morph target or a dedicated stable bridge. Cancel must not wait behind the view/selection queue. It changes only cancel_requested; server confirms the actual terminal cancelled state. After accepted cancel, the job cannot publish completed/result. A cancellation arriving after completed returns the already terminal completed snapshot and explicitly does not claim cancellation.

## Case selection without browser mining

Show up to 20 case rows initially in a server-rendered case card: generated internal case ID, escaped optional name, event count. Selected-case activity details show at most 200 events; full selected-case data is available in JSON. No search, paging or enterprise storage in this short T08. Explain the display limit; full cases remain in server memory.

Extend existing POST /logs/{id}/selection with kind=case and a generated case ID. Reuse the serialized mutation bridge; server validates case ownership. Case choice does not alter global counts, variants or threshold. Store selected_case_id separately from selected_id for node/edge, so clicking an element can show its aggregated count alongside the selected trace.

Graph payload additions, computed only by server:

```json
{"selected_case_id":"case-3","case_highlight":{"node_ids":["n0","n2"],"edge_ids":["e2"]}}
```

The adapter applies a visual class to these known IDs. It does not reconstruct sequences or calculate edge frequencies. Highlighted edges are the intersection of the selected case transitions and current GraphView edges. A threshold never reintroduces a hidden edge. Case detail lists its ordered activities using escaped HTML and states: “Частоты на карте относятся ко всему журналу”. If all case edges are hidden, show “Переходы этой трассы скрыты текущим порогом”; retain the selected case and original details. Empty cases show an empty sequence, not a fake start/end.

Case selection and view changes increment the same monotonic view_revision. Selection survives threshold changes when the selected case still belongs to the same log; a new log clears prior case/element selection and resets graph fitting. The unified request queue prevents out-of-order HTML panel mutation.

## Memory limits and enterprise boundary

Explicit copy: “Задачи и журналы находятся только в памяти. Перезапуск прерывает задачи и удаляет результаты. Это локальный прототип без авторизации”. Preserve the actual last-eight-log cap; completed jobs must not pin unlimited extra journals. Evict the oldest terminal snapshot beyond the proposed cap of eight; snapshots store result IDs and lightweight status, not duplicate EventLogs. No database, durable queue, multi-user isolation, external access or enterprise-readiness claim in T08.

## Independent acceptance additions

AC13: actual queued/running/stage/terminal sequence; /health and view requests stay responsive; accepted cancel cannot lead to completed; repeat cancel and post-completion cancel have truthful snapshots; reconnect does not duplicate results; busy/full queue preserves old analysis. Test both cancellable controlled work and non-interruptible parser messaging. Record what was actually tested.

AC14: select distinct cases with duplicate names, an empty case and a self-loop; compare case details to independent fixture; change threshold; highlighted IDs remain a subset of visible graph; global stats and export stay consistent; rapid interleaved case/element/view actions settle on the same versions. Pan/zoom persists for the same log.

Security: file/log bounds remain enforced server-side; job IDs and case IDs are generated, activity names never enter expressions; CSP and local dependency tests rerun after integration. Missing evidence means unverified, never inferred PASS from a screen.


## Exact implemented UI hooks

Shell token JOB_PANEL is supplied by root; default is an empty hidden section with id=job-panel. Root owns safe generated events/cancel endpoints and all visible job stage text. The stable job-connection owns data-init; job-panel never owns the stream initializer. HTML data-job-state uses Rust Debug casing (Queued, Running, Completed, Failed, Cancelled); JSON uses snake_case. Use job-card, job-header, job-stage, job-memory, job-terminal/job-error classes. The stream is finite: it sends current snapshots through real job completion/cancel/failure, then closes. No progress percentages are required.

Analysis-panel tokens CASE_ROWS and CASE_DETAILS are supplied by root. A row is a button with class case-button, type=button, generated data-case-id, aria-pressed, and static data-on:click="window.piQueueCase(el.dataset.caseId)". Name and event-count spans are escaped server values. No value is interpolated into the expression. piQueueCase reuses the stable unified mutation bridge with kind=case.

The adapter styles only known graph IDs with amber case-path class. It preserves pan/zoom for the same log and respects server selected_id independently. Selected element green has precedence over case path amber. piGraphSnapshot diagnostics additionally expose selected_case_id and highlighted IDs for independent QA.

Author validation: node --check static/app.js passed. Browser and integrated job/cancel/case acceptance remain independent QA work; source completion is not PASS.

The existing node/edge selected details region has stable id=element-details. Case detail uses id=case-details. Independent browser tests must scope these explicitly instead of the now shared selection-details class.



T08 stale-result refinement: server emits a completed job analysis patch only when its result_id is still repository.current. The adapter independently restores its cached accepted analysis panel when an older analysis/view arrives. Job panels remain outside this cache. Old completed job views use an explicit result link; reconnecting an old stream must not switch the current analysis. Deterministic browser injection of an old panel tests the presentation guard only, not mining correctness.
