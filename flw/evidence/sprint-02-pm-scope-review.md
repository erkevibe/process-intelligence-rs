# Sprint 02 PM scope review before candidate freeze

Reviewer `/root/pm_final`, original PM seat. This PM also authored the BPMN module and UI/renderers during this sprint, and therefore **does not independently accept or test those own changes**. Product acceptance belongs to independent QA, separate TechnicalDebt, Customer and the fixed council. This document checks requirements and claims, not product PASS.

Basis: exact accepted S2-P1, README, ROADMAP, SPRINT_02_SPECIFICATION, own UI contract, current integration source, attributed draft QA observation and separate debt findings. Full source SHA is not frozen at this review; none of the older passing runs proves final source/package identity.

| Criterion | Current implementation boundary / evidence requirement |
|---|---|
| A01 | CSV five-row preview, explicit column mapping and quoted/Unicode input. Draft QA reports actual browser CSV import and row-error preservation; final candidate replay required. |
| A02 | Source/timestamp policy, stable tie order, timestamps required for timestamp order, each-event lifecycle and source SHA in export. Final independent exact-sequence assertions remain mandatory. |
| A03 | Real PostgreSQL transactional repository, persistent scoped IDs and per-user views. Draft QA reports actual restart; frozen build and original committed-state preservation required. No SQLite substitution. |
| A04 | Versioned hashed raw project bundle, atomic restore into a new owned project, no auth/session/membership content. Original bytes are the supported restore input; documentation explicitly warns against reserialization. Corrupt restore must preserve prior data. |
| A05 | Server-scoped project membership and owner/editor/viewer checks. Renderer hides forbidden forms; this is presentation, not proof of authorization. Distinct-session known-ID denials across every route and role actions remain necessary. |
| A06 | Local setup/login/logout, Argon2id, token hashes, bounded sessions and same-origin controls. No SSO/TLS/shared deployment claim. Independent session invalidation and secret-free outputs required. |
| A07 | Accepted and terminal jobs persisted; result/completed publication and cancellation share durable boundary. Actual crash recovery and no orphan/duplicate result required; observing in-memory job tests alone is insufficient. |
| A08 | Strict one-process BPMN subset with explicit unsupported rejection; caption/position editor and semantic round trip. Aggregate model admission/exportability added after source review. Final independent save/reload/XML and authorization checks required. General topology editor not claimed. |
| A09 | Named observed-variants choice baseline with separate paths and empty bypass. Independent manual DFS language oracle reported in module tests; no unseen-behavior, quality or Split Miner equivalence claim. Edited-label model captions distinguish method origin from unchanged observed sequence. |
| A10 | Server trace predicates then event projection, immutable source and recomputation. Friendly searched checkboxes/chips serialize hidden policies only; bounded/stale-response guarded UI is newly changed and awaits final independent browser replay. Native all-filter reset included. |
| A11 | Fixed-offset working intervals, weekdays and holidays with explicit no-DST boundary. Newly added human table displays server-provided integer milliseconds exactly in hours/minutes/seconds/milliseconds; missing time stays unverified. Table is presentation only; independent calendar oracle and final browser data remain mandatory. |
| A12 | Fixed source, clean build/start/restart/package, R1 regressions, full native browser chain and negative tests. This gate is still pending at review. Separate package source-identity debt finding must close before release. |

All twelve remain mandatory. Completing individual modules or most scenarios cannot turn failed security/durability or missing evidence into a complete sprint. If any criterion fails or is unverified at deadline, publish partial status per criterion. Last 90 minutes remain protected for verification and delivery; actual elapsed time must be recorded.

## Documentation conclusion

README correctly says R1 accepted and version 0.2 undergoing independent acceptance. ROADMAP explicitly retains the original R2–R5 exit criteria. New specification identifies selected slices and their typed policies/caps: UTF-8 CSV, source/timestamp order, BPMN node/flow/label and aggregate limits, fixed-offset calendar/span, persistent project capacity, session/project/user bounds and original-byte backup. No full original-stage, Apromore oracle, Split Miner, DST, migrations, SSO or enterprise-ready claim is found in the reviewed descriptions.

The previous R1 memory-only/rolling-eight behavior is historical. Persistent R2 project capacity now rejects the ninth log while retaining all prior committed logs; new list text states this. Future infrastructure recovery, migrations, audit trail and expanded security remain explicit follow-ups. Source/evidence of admission caps does not establish a total process memory ceiling.

## Remaining review gates

Final freeze, independent exact-source QA/TD, actual clean packaged replay and complete claim-to-evidence matrix are required before a PM final vote. Updated activity picker and calendar table must be integrated before that frozen browser run. This review establishes no new feature requests and no current broad STOP; separate auditors retain their actual findings and authority. The human user's acceptance is not impersonated.
