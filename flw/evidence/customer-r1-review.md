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

## Final exact P3 vote

Customer /root/customer votes FOR exact P3 proposal with SHA256 `630C01BB1F6AE957CF3AA1EF11E4E8CCCE43C371F1970321C5CECF0DDAE8CFBE`, verified from actual flw/evidence/p3-proposal.md. Candidate source is `b12554fcda6ff801392326bea85f0714221a9246`.

Read independent qa-final-b12554.md, qa-final-coverage.json, debt.md and package-b12554.json. Final QA reports fresh pinned clean checkout and actual native launch; 30 contract tests; browser base14, optional10 and stale5; small corpus20; exact release admission11 and packaged browser14. QA explicitly maps AC01–14 to actual evidence, attributes CI metadata without claiming raw log coverage, and limits memory measurement honestly. Previously pending stale-panel check now has final frozen clean replay evidence. Customer does not claim to have rerun these tests.

Scope accepted: local memory-only R1 prototype with optional jobs/case interaction; restart loss, latest-eight logs, bounded jobs, cooperative cancellation with noninterruptible third-party phase, UI subsets with complete JSON, precise per-job RSS unverified. The measured 25ms parse+analysis/31.70ms HTTP benchmark is scoped to the stated synthetic input and machine, not a general speedup claim. Minor UX-C01–04 are deferred to R2. Legacy equivalence, persistence, multi-user security and enterprise readiness remain future/unverified.

Vote approves the exact conditional delivery resolution; independent final QA/TechnicalDebt gates and council majority remain required. Reporting-only commits must preserve frozen production identity. Human user's final acceptance is not replaced by this Customer role vote. No blocking Customer objection remains in this reviewed local scope.
