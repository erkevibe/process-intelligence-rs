# Sprint08 — Customer draft runtime/source review

Reviewed full draft docs/SPRINT_08_RUNTIME.md and selected source UI ranges in platform_render.rs, plus README/ROADMAP current introductions. First combined output truncated; targeted follow-up captured audit, folder and preview render logic, although an unrelated tail of logs/model rendering remained truncated. This is source/document review, not actual browser, PostgreSQL or final acceptance. No runtime/shared source/old-data changes by Customer.

The useful operator contract is concrete: mixed preview shows counts and source-indexed default/removal actions before explicit confirmation; original bytes/hash and history remain separate from mutable settings. Empty projections are blocked; strict import survives. Limits, TTL, two pending sources,64 statuses, cancel-after-confirm refusal, uncertain-persistence fail-closed and no automatic restart deduplication are disclosed. These limits should remain visible in final operator docs rather than suggesting an unlimited durable job workflow.

## Concrete pre-freeze priorities

1. Folder ambiguity: options use only folder.name while same names are permitted under different parents. A/Reports and B/Reports are indistinguishable when assigning a journal/model or choosing a new parent. Display validated full paths in selectors and relevant table columns, with a short ID if still necessary. This is a real product usability defect in the described supported hierarchy, not a request for broader folder scope.
2. Preview reasons: human HTML currently renders English machine codes. Render understandable Russian labels for missing_activity, missing_timestamp, unsupported_lifecycle, empty_case and missing_lifecycle; retain stable codes in JSON. Actions and fully filtered warning are already clear. Show that default counts can include events subsequently removed, so the count does not imply retained events.
3. Archive access: project UI says archive closes access to modification; draft contract says access to the project is closed until restore. Align visible description with actual implemented read/write behaviour and independent tests. Data remains, owner restore and alternate-project requirement stay explicit.
4. Repeat confirmation: UI currently promises the same journal on repeat without the draft's qualification that only retained statuses support this. A brief qualification prevents implying indefinite idempotence or post-restart upload deduplication.

## Historical identity and preservation

Draft correctly distinguishes immutable source/history binding from authenticating the external identity of a historical actor. New-project restore retains historical actor/project IDs while new changes use the new project ID; show this warning near history export or in linked operator guidance. Do not rewrite old identity merely to match the new project. Full DB backup includes auth/admin history; semantic project backup does not export credentials/sessions/admin auth document. Old plain logs explicitly lack unavailable source/history rather than fabricating them.

Bounded512 repository and512 project administrative histories,200-row view/full retained export and total/dropped are an honest operational contract, not permanent/legal security audit. Metadata-only organisation, no cross-project moves, empty-only deletion, stable IDs and CAS remain essential QA targets. Downgrade unsupported/new envelope is clear; use new restored DB and preserve protected0.1–0.5 data.

No full R2–R5 closure claim was found in the reviewed candidate contract. IANA/DST is a bounded named-zone calendar contract, Alpha+++ is explicitly developer-only and not SplitMiner or measured BPMN quality. README/ROADMAP still describe prior accepted versions; they must be updated after actual acceptance with the full15 matrix, not promote candidate capabilities prematurely.

Customer recommends addressing the four narrow clarity defects before freeze, then actual browser/persistence/negative/source binding acceptance. No evidence-based STOP for data loss or security can be inferred from this source review alone. Full paths are important to make the promised hierarchy usable. Final vote awaits exact candidate and independent QA/TD/CI/package proofs.
