# UI contract: selected R2–R5 scenarios

PM owns `src/bpmn.rs`, `templates/platform.html`, `static/platform.js/css` and this contract. Root owns server routes/auth/storage and fills templates. No browser role or authorization calculation; server checks each native form/action and asset-free export.

## Shell

`platform.html` replacements: `{{NONCE}}`, escaped `{{TITLE}}`, server-rendered escaped `{{BODY}}`, `{{NAV}}`. NAV is trusted renderer output, never user HTML. Same CSP nonce/header policy as R1. Existing R1 shell adds `{{WORKSPACE_NAV}}`; root must replace it with authenticated project/navigation links or an empty string. XES upload route and R1 Datastar hooks remain unchanged. CSV is a separate native route/form from workspace navigation.

Native server forms use `.platform-form`; headings/cards `.platform-heading`/`.platform-card`; errors `.platform-alert` with role=alert; success also `.platform-success`; tables `.platform-table` inside `.platform-table-wrap`; multi-column forms `.platform-fields`. Forms should show project name, server-confirmed role, import/order/filter policy and persistence status using ordinary Russian text. Failed validation preserves existing stored result. Viewer receives no write buttons, but server denial remains mandatory for forged requests.

## BPMN diagram/editor

Render inert escaped JSON inside `<div id="bpmn-data" hidden data-editable="true|false">...ProcessModel...</div>`. JSON is element text, not executable script. Stable island: `<div id="bpmn-cy" role="img" aria-label="Модель процесса BPMN"></div>` within `.bpmn-diagram`, graph fit button `#bpmn-fit`. Local Cytoscape renders task rectangles, generic event circles, XOR/parallel diamonds. Diagram coordinates use top-left x/y as in BPMN Bounds, converted to canvas centers; waypoints remain in serialized model.

Native edit form `#bpmn-save-form` action belongs to root's authorized model-save route. Hidden input/textarea `#bpmn-model-json` name=`model_json` receives the complete draft. Optional model-name field can be server-side form field. Node fields `#bpmn-node-id` readonly, `#bpmn-node-label`, number fields `#bpmn-node-x` and `#bpmn-node-y`; button `#bpmn-apply-node` type=button updates the local draft, then native Save POST validates/stores on server. `#bpmn-node-hint` explains selection; `#bpmn-status` role=status announces unsaved changes. All node controls start disabled until selection. Viewer data-editable=false prevents canvas dragging and local edit controls; this is presentation, not security.

Only captions/positions are edited through this small island; topology can be changed by importing another validated BPMN. Backend model JSON must use `bpmn::validate` before atomic save. Export uses `bpmn::serialize`, preserving IDs/labels/flows/x/y and explicitly provided waypoints. Width/height are validated input drawing attributes and normalized to canonical dimensions; only x/y are part of ProcessModel. JSON `discovery` provenance is retained by storage/export JSON; BPMN XML contains no custom extension, so parsing that XML returns discovery=None. The algorithm name and limits remain in page/report metadata, never an unsupported XML extension.

`ProcessModel` schema_version=1; process_id/name strings; nodes/flows as root contract. Labels empty permitted, <=4096 UTF-8 bytes. IDs are bounded unprefixed XML identifiers; coordinates finite ±1,000,000; flows have empty waypoints or 2–256 points. Discovery observed_variants_choice_v1 uses unique exact observed sequences, XOR separate paths and empty bypass; no inferred parallelism or unseen behavior. No truncation when model limits exceed 1000 nodes/4000 flows.

Independent browser verifier may read `window.piBpmnSnapshot()` (cloned draft, selected_node_id, pan/zoom, editable). Syntax/source review is not integrated browser acceptance. Server-authorized save, reload and XML reparse require actual checks.

## Activity filter picker

Retain/remove policy remains server-side. Native POST `/logs/{id}/filter` receives existing hidden fields `retain` and `remove` as JSON arrays; users see searched checkbox labels and selected chips, never a JSON textarea. Each `.activity-picker` fieldset has `data-field="retain|remove"` and an escaped local `data-source="/logs/{id}/activities"`. GET adds `q` and returns `{activities:[exact_label],has_more:boolean,total_activities:number}` with at most 50 matches from the immutable source log. Root owns this authorized endpoint.

Adapter debounces search 200 ms, aborts previous queries and rejects stale responses. A Set retains all choices across searches. Labels are created with textContent and checkbox values assigned as DOM properties, preserving exact Unicode and multiline strings without HTML-parser normalization. Hidden JSON is updated on each local choice; only native form submit applies the server filter. Chips show the first 50 choices with total if larger; all choices remain in hidden transport, searchable and clearable. `[data-activity-clear]` clears that picker draft. A separate native `Сбросить все фильтры` form submits empty case/min/max and both empty arrays immediately.

Independent browser checks should select `[data-field="remove"]` checkbox by exact value/label, change search and verify selection retained, remove chip/clear, apply and inspect actual counts/export, then reset and inspect restored source counts. Include an activity with Unicode/newlines and HTML-looking text, plus an out-of-order search response; no browser calculation of filtering is introduced.

## Calendar display

`platform_render::calendar_table` accepts the already computed `platform::calendar_results` JSON Value and renders a human table, not raw JSON. It shows case ID, exact server integer milliseconds formatted into hours/minutes/seconds/milliseconds, and computed/unverified status. Missing timestamps display «Нет времени событий», never zero duration. At most 200 rows are displayed with an explicit full-export note; `business_durations` in the journal export remains complete. The renderer performs no calendar calculation and cannot replace independent interval/oracle assertions.
