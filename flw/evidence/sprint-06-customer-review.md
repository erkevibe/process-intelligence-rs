# Sprint06 — independent Customer candidate review

Reviewed: docs/XES_ORACLE.md and docs/SPRINT_06_REPORT.md candidate text. This is a Customer position, not final QA, a release vote, or proof of execution of private raw logs. No runtime, database, installation or shared document was modified by Customer.

The result has useful customer value: comparison now passes the original XML to a genuine upstream parser and XLog consumer, instead of comparing sequences already normalised by an external text adapter. Ten selected examples expose concrete boundaries that matter when replacing Apromore. The six preserved examples provide continuity with the prior accepted behaviour.

The documents distinguish source order from Rust's explicit timestamp order, preserve stable ties and equivalent UTC offsets, and do not silently merge lifecycle events. They record the upstream invalid-time exception and three differences: wrong timestamp type, duplicate semantic name and submillisecond precision. These findings should remain visible; automatic weakening of Rust's validation would not be an acceptable compatibility fix without a separate user-facing contract.

The scope is stated honestly: parser/consumer only, explicit factory/classifier, no service validateLog or Portal import, no IANA/DST or discovery/BPMN quality claim. Manual Rust expectations and consumer consistency are separate from broad compatibility. Arbitrary untrusted XML safety is not claimed. Production/runtime remains accepted Windows0.5; a new package is unnecessary when no runtime changes exist.

Customer supports final acceptance only after independent final replay and exact revision CI, bounded ProcessLogAuditor/TD review and the new final Council vote. Candidate pending rows are correctly still pending. This review does not independently attest to the claimed executions or upstream hashes.

Next priority: first choose the needed service-import contract using the newly exposed differences, especially validateLog filtering of lifecycle/time/name/empty traces, and add a small fixed corpus with real outputs before implementing compatibility changes. Separately, DISK01 remains a concrete operational priority: explicit cleanup only after verified full backup/new restore and independent conservation/rollback proof, with its own destructive-test budget. Native5 backup stays unverified. Neither debt is closed by this oracle sprint.

Customer's original cleanup preference is retained in the backlog; the bounded real-XES result is accepted as a useful prioritisation within the four-hour research/verification window. Final vote reserved for the exact proposal.
