# Customer review R1 before final candidate

Reviewer: independent Customer agent /root/customer. Scope: user comprehension; no release acceptance or council vote. Reviewed app18 localhost:3000 and current templates/source, docs/SPECIFICATION.md and docs/R2_SCENARIOS.md. No POST requests, uploads, cancellation or state mutations performed by this review.

## Evidence and limits

- Independent GET http://127.0.0.1:3000/ returned HTTP 200 with rendered analysis and Russian instructions.
- Inspected QA screenshot `.local/qa-browser-optional18/optional-case.png` visually. It shows synthetic semantics.xes, threshold 2, selected two-event self-loop case, counts and case details. This screenshot is QA evidence, not a fresh Customer browser run.
- Read `.local/qa-browser-optional18/report.json`: ten reported passes including completed/failed/cancelled jobs, terminal reconnect, empty case and case selection with hidden edges. These results are attributed to QA and are not claimed as independently repeated by Customer.
- Read actual job and case text in src/web.rs and templates/shell.html. CUA browser startup failed because Windows sandbox helper setup failed. Therefore fresh browser interactions and responsive/mobile rendering are unverified by Customer.
- No sensitive material encountered; screenshot and current page use synthetic fixtures. No source changes made.

## Facts and user value

1. Upload presents XES, byte/event limits and an explicit Analyze action. Background processing is an opt-in checkbox. User can understand the basic entry point (AC06).
2. Threshold has a visible explanation that only edges change and source statistics stay unchanged. JSON export sits next to the result. This addresses CUST-02 and the earlier threshold semantics concern (AC02/06/10).
3. Case list distinguishes internal IDs even with absent names; selected case shows ordered events and an explicit message when its transitions are hidden. Highlight legend and note say graph counts cover the whole log, which avoids confusing a selected case with filtered statistics (AC14).
4. Job text distinguishes requested cancellation from terminal cancellation and explains waiting for a safe stage boundary. Failed/cancelled states say the previous analysis is preserved. These messages match the useful semantics of AC13; execution proof belongs to QA.
5. The interface explicitly explains XML order, separate lifecycle events, absence of causality/parallelism, memory-only storage, last-eight-log retention, loss of job history after restart and unverified Apromore compatibility. R1 boundaries are visible, rather than concealed behind the project name (CUST-05/08).
6. R2_SCENARIOS.md includes the eight independently proposed scenarios and enterprise boundary. CUST-09 planning action is now represented; implementation remains future work.

## Remaining UX risks and proposals

- UX-C01, P2: The critical restart/loss warning is below the tall analysis panels. At the screenshot viewport it requires scrolling. Proposal for a later polish iteration: a short warning beside JSON export or upload, while retaining the fuller explanation below. Current visible sidebar says only data is in memory. This is a discoverability risk, not an AC blocker established by this review.
- UX-C02, P2: Background mode's benefit and cancellation availability are mostly in a tooltip/job panel. Proposal: a brief label such as background processing allows progress and cancellation. No need to add a workflow or promise persistence.
- UX-C03, P2: The reviewed graph is intentionally zoomed/panned and two nodes are partly clipped. Fit and zoom controls are available, matching the preserve-pan requirement. Avoid automatic refit during filtering; optionally explain Fit to new users. No evidence of broken layout from this screenshot alone.
- UX-C04, P2: Technical Rust4PM wording appears in the job storage note. A simpler public explanation could say cancellation waits for the current parsing stage. Keep implementation details in the report.

## Position

The observed interface supports the intended local R1 scenario and communicates its boundaries. No Customer UX blocker is demonstrated in this limited review. This is not evidence that all AC01–14 passed: final acceptance must use fixed candidate SHA, clean run, independent browser evidence and remaining stale-panel checks. No final council vote cast here.
