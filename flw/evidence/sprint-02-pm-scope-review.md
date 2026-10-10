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

## Final PM position before package gate (source08)

Repository HEAD independently read as `c0180a2bf0069b599f112226a10a13f67ce82f17`. Exact accepted-plan hashes independently recalculated unchanged: SPRINT_02_PLAN `2FA33BCCDDED13CB74C015F3FEA59D1EE0CA05A1B450C748051B321DCF81D7BB`; incorporated PM plan `10AEFF23D19F63B077677F9870EFF0E355300CFAFA324B8BB914E18BF169085B`. No acceptance criterion has been removed or renamed.

Read independent QA final04 and candidate06 reports. They explicitly preserve superseded source identity, actual A01–A11 checks, actual process restart with equal-filename distinct IDs, role/foreign-ID denial, atomic invalid restore and job recovery. They also explicitly mark mandatory A12 failed/pending rather than averaging it away. These reports are attributed independent evidence; this PM did not author or execute their verifiers and does not transfer their PASS to source08 by assumption.

Read current package report identifying source08 and ZIP SHA256 `E667726FECDEB5BC41183F2025B4FA1E6803879A65388D6F7AE3C656313CBF87`. Report records 1635 manifest hash/size checks, fresh bundled PostgreSQL first initialization/non-superuser transaction probe, and Windows PowerShell 5 role-present/missing-database recovery. These are root-executed package checks, not PM-executed tests. Native public launcher plus independent exact08 packaged browser/start/restart proof still pending at this position. ZIP identity alone cannot establish A12.

Independent PM proposal: accept only after final exact08 QA and separate TD closure of package/source-identity gates, then actual fixed-council majority. Scope remains all twelve selected-slice criteria, local PostgreSQL platform, strict BPMN/observed-variant baseline and fixed-offset calendar. Original full R2–R5 exit criteria, legacy compatibility, advanced discovery, migrations/shared deployment and enterprise readiness remain future/unverified. Report actual wall time from 06:40:06 UTC, including failed package attempts; no assertion that eight hours were consumed.

Prior ACL SeSecurityPrivilege, occupied-port startup and native PowerShell 5 UTF-8 launcher parsing failures remain historical failed attempts. Narrow fixes require exact source/proof and successful actual launch; they are not retroactively relabeled as successful. Residual database deadlines, workload/RSS limits and interrupted bootstrap-config recovery belong to the explicit TD follow-up plan with owners, not a global zero-debt assertion.

No PM scope blocker remains demonstrated. **No final vote or completed-sprint acceptance is cast while A12 remains pending.** This PM's production authorship still excludes independent acceptance of its own BPMN/UI code; separate QA is mandatory.

## Actual final PM vote on S2-R1

The preceding pending position is superseded by newly completed exact-package evidence, not by reclassification of old failed runs. Read full release proposal `council-s2-release-proposal.md` and independently recomputed its raw SHA256: `5B192A75F27F37691F48C25A5A99E54EB27337DDFC7557DB0731BEE8D27E2135`.

**Real PM vote: FOR this exact S2-R1 proposal**. Accepted runtime source: `c0180a2bf0069b599f112226a10a13f67ce82f17`; version 0.2.0; EXE SHA256 `79DD6F1FDD43D62FCF5A8EBDF6DA6B74A8C7AF0E02713A2DFCFF7B3FD7ADD657`; ZIP SHA256 `E667726FECDEB5BC41183F2025B4FA1E6803879A65388D6F7AE3C656313CBF87`. This is a new release vote, not reuse of the planning vote, and one existing PM seat.

Basis: read `sprint-02-qa-c0180a2.md` and `sprint-02-qa-package08.json`. Independent QA now records all A01–A12 passed in the selected scope: actual exact08 checks repeated, 49 ordinary tests plus two separately executed real PostgreSQL tests, source/hash checks, fresh 1635-file manifest verification, non-administrative protected ACL and bundled PostgreSQL startup, native Windows PowerShell 5 Start, packaged browser before20/roles5/UI3, and actual packaged process restart 43320→9760 followed by after4 checks. These are QA-executed/observed evidence, not this PM's execution. They close the previously pending A12 PM gate.

Claim boundaries remain correct: all twelve unchanged mandatory criteria, true PostgreSQL, local selected slices, strict BPMN and method-origin caption after edits, fixed-offset calendar, no enterprise or complete original-stage claim. Reporting-only commits must preserve accepted runtime/package bytes and state merge/tag SHA separately from archived source SHA. Release remains subject to real council majority, separate auditor conclusions and any mandatory STOP; this vote waives none of them.

Historical missing/overwritten stderr coverage is explicitly retained as missing, rather than claimed complete. Database deadlines, measured workload/RSS, interrupted bootstrap-config recovery and remaining UX are accepted bounded follow-ups with their recorded owners/closure conditions. Human final acceptance is not impersonated. Actual finish/time must still be recorded after publication and installation within the existing deadline.

PM authored production BPMN/UI and therefore accepts requirements/claims on the basis of **separate independent QA**, not a self-QA verdict. No source or runtime change was made by this final vote.

## S2-R1 withdrawn; actual new PM vote S2-R2

After the preceding S2-R1 vote, the root reported a newly observed full cold native Windows PowerShell 5 installation failure: PostgreSQL was ready but null Start-Process ExitCode caused a false failure. Separate TechnicalDebt opened COLD01/A12 STOP. The prior PM S2-R1 vote is **historical and withdrawn for delivery**; it cannot authorize source08 publication and is not transferred to a new package.

Read full new proposal `council-s2-release-proposal-02.md`, independently recalculated raw SHA256 `FAB3BF5228599D0C22F4024912258F61626CF9D5416A0F93349435F1B1F86C98`, and read new independent `sprint-02-qa-d0784e.md` plus `sprint-02-qa-package11.json`. Source HEAD independently read as `d0784e2766f5af875225e62f85aa11f85ccce5d9`; original S2-P1 hash recalculated unchanged. The new proof concerns a narrow retained-process-Handle repair and an actual new cold-start branch, not readiness-test removal.

**Real new PM vote: FOR exact S2-R2, raw proposal hash `FAB3BF5228599D0C22F4024912258F61626CF9D5416A0F93349435F1B1F86C98`.** Runtime source `d0784e2766f5af875225e62f85aa11f85ccce5d9`, EXE SHA256 `E2189EA8C463E7E3E146EF7983608A95F474B2FFA35FA02555F8A0CF3E47986E`, ZIP SHA256 `E075D999D03729CFC453CCE67BC1400F9413AD7111B750FE873F998D5B47A739`, selected version 0.2.0. One existing PM seat; this is neither the planning vote nor old release approval.

Basis: separate QA reports all selected A01–A12 passed anew on exact11, separately executed real PostgreSQL tests, full selected app chains and true restart, 1635-package-file hash/size verification, protected non-admin ACL, actual native PowerShell 5 cold initialization and public Start on two fresh clusters (package and independent user installation), package-CWD before20/roles5/UI3, and real package process 37824→820 followed by after4 checks. Both actual executable hashes match the new proof. These are independent QA/root evidence, not PM-executed own-code acceptance.

The vote supports the proposal's explicit condition of real majority and absence of mandatory STOP. It does not independently override TechnicalDebt's COLD01 authority: final exact-package closure/resume and council resolution remain required before publication. Historical native failures and missing raw stderr stay retained as failures/missing coverage. Full original R2–R5 and enterprise/legacy parity remain future work; no criterion was weakened.

Permitted reporting and the single non-runtime Linux health-smoke `PI_EPHEMERAL=1` adjustment do not change accepted runtime bytes or tests. Future CI outcome and PostgreSQL CI parity are not presumed. Source archive commit and merge/tag reporting commit must be stated separately. Actual elapsed time includes the cold-start failure, repair and renewed verification and is recorded after delivery within the original budget.
