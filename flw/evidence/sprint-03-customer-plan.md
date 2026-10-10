# Sprint 03 independent Customer position

Owner /root/customer, existing Customer council seat. Read current ROADMAP and SPRINT_02_REPORT. Planning only, no runtime or live-user data changes. Start supplied by coordinator11:37:57UTC, eight-hour ceiling19:37:57UTC; preparation/setup/QA/delivery included. Fixed five seats Root/Customer/PM/QA/TD. No exact plan vote yet.

## Priority and customer acceptance

| ID | Priority | Desired user result and actual acceptance |
|---|---|---|
| S3-C01 | P0 user requested comparison | A reproducible small XES example runs on fixed actual Apromore version and Rust version with identical normalization/parameters. Report actual cases/events/activity counts/variants/DFG frequency results side by side, input SHA, legacy SHA/version and command/UI settings. Every difference is explained or open, never averaged away. |
| S3-C02 | P0 honest oracle boundary | Timebox bootstrap diagnostics. If actual oracle cannot run, publish blocker and reproducible frozen input/expected manual results; mark Apromore parity unverified. A Rust/manual corpus is useful but does not satisfy C01 actual comparison. Whole-sprint status remains partial if comparison is mandatory and unavailable. |
| S3-C03 | P0 preserve working installation | Upgrade a copy of actual0.2 data to the new version, reopening two same-name logs, policies, users/roles, saved models and job results with same IDs/hashes/exports. Existing live apps/data remain untouched; only verified backup copies used for upgrade tests. |
| S3-C04 | P0 migration safety | Versioned migration is transactional/repeatable. Crash or deliberately injected failure before completion leaves a usable old or new store, never half-migrated success. Newer unsupported schema fails clearly without changes. Concurrent migration attempts cannot double-apply. |
| S3-C05 | P0 setup recovery | Interrupted initdb/private-config setup can resume safely from a controlled real fault at the known gap. No new credentials overwrite an existing cluster; wrong configuration fails explicitly. Cold native WindowsPS5 install/start and repeat start prove usability on the exact final package. |
| S3-C06 | P0 bounded outages | A unavailable/locked PostgreSQL returns a bounded understandable failure and false health readiness; requests do not hang indefinitely or show durable success without commit. Recover/restart retains previous data. User receives a next action without secrets or SQL dump. |
| S3-C07 | P1 recovery operation | User can identify backup time/schema/version and recover into an isolated destination. Upgrade/recovery evidence proves role isolation, interrupted jobs and source integrity remain correct. Document actual recovery steps and stopping scope, not a generic assurance. |
| S3-C08 | P1 smallest worthwhile BPMN | Add/remove a generic task and connect/disconnect a sequence flow in the current supported subset, with clear draft/saved state. Removing a task explicitly removes incident flows; invalid IDs/dangling edges reject without changing saved model. Save/reopen/export/import preserves edited structure and positions; viewer cannot edit and foreign projects deny known IDs. |
| S3-C09 | P2 existing UX | Apply current edited node fields when Save is pressed, or visibly warn they are unapplied; clarify password requirements without byte/character surprise. Do not enlarge BPMN semantics just to improve these interactions. |

## Scope judgement

The operational guarantees protect existing user work and take precedence over BPMN breadth. C08 is the smallest structural extension with real customer value; labels/coordinates alone were already delivered. Adding service tasks, subprocesses, conditions, collaboration or advanced miners before migration/crash gates is unjustified in this eight-hour iteration. If budget tightens, mark structural BPMN partial/deferred explicitly rather than dilute safety gates. Preserve the final90min for fixed-package independent replay and delivery.

Actual Apromore comparison should target frequency behavior first, not browser pixel identity or XML BPMN equality. Do not conflate R1 integer edge threshold with Apromore percentage/connectivity filtering. Lifecycle/timestamp/global defaults require identical explicit normalization or reported mismatch. Small concrete example is more trustworthy than a general parity headline.

Risk appetite: medium overall, low for data/migration/auth/recovery, high for bounded exploratory oracle/bootstrap and structural-editor UX. No new Customer STOP is asserted from planning alone. Demonstrated data loss, unauthorized access, destructive upgrade or false success blocks the affected delivery; independent QA/TD cannot be replaced by a council majority. Existing actual0.2 acceptance is not automatically proof of the changed candidate.

## Council continuity and emotions

Await the actual separate PM/emotional agent's nine fact/problem/proposal perspectives; Customer will not fabricate them. No human emotional questionnaire or repeat permission required. Exact resolution, owners/checkpoints and mandatory versus optional claims must be frozen before implementation; final vote only on that resolution. This role does not replace human user acceptance.

## Actual plan vote S3-P1

Customer /root/customer votes FOR exact docs/SPRINT_03_PLAN.md raw SHA256 `A33E3CE16F8E585AB288162BBCD684A054D183FF4B1F52266CE41A218746FB7F`, independently computed after reading the full actual proposal. This is a new plan vote, not a release acceptance or inherited previous vote.

Basis: the plan preserves user-requested actual legacy comparison with an honest45min gate and six-example corpus; protects existing live installs; requires isolated0.2 upgrade/DB restore, atomic version/checksum migration and operational A03–09; explicitly bounds database faults and does not claim timeout implies rollback; stages secrets before initdb; puts narrow task/flow editing after operational gates and protects final90min. These address the prioritized Customer acceptance requests.

Accepted schedule limitation: A02 may be BLOCKED and A10 PARTIAL, each reported without credit or a full-goal completion claim. Operational failure blocks affected storage release even if oracle/UI work passes. New0.3 remains separate from current user0.2; returning to0.2 uses preserved old database/backup, not unsupported downgrade of upgraded data. Complete enterprise/oracle parity is not inferred.

Requested actual nine perspectives from pm_final for this sprint and will append attributed input when delivered. No human permission reprompt; no runtime edits or existing application changes by Customer. Final product acceptance still requires frozen-source independent QA/TD and a separate exact resolution.

Actual separate PM perspectives received: Joy asks a concrete-example comparison that preserves working0.2; Sadness asks explicit BLOCKED/PARTIAL oracle diagnosis; Anger asks failclosed/durable reread instead of timeout-as-rollback; Fear asks copied DB/backup/actual restore; Disgust asks secret-free public evidence; Anxiety asks staged recognizable bootstrap resume without reset; Envy asks exact legacy component and parity limits; Shame asks clear draft/saved BPMN and Apply/Save checks; Boredom asks the45min oracle gate and final90min. Customer has considered these attributed fact/problem/proposal inputs; they are not human emotion claims or extra votes.

## Actual targeted vote S3-RESUME-1

Customer votes FOR sprint-03-bootstrap-resume-proposal.md raw SHA256 `2EEE2A43D569CEF06CC1F9823B66D4DB3D89D48E3183AB042B91BA634974C8DD`, independently computed after full read. Read actual independent sprint-03-qa-observation.md closure evidence: nativePS5 resumes the same preserved5557 cluster with identical staged credentials/original-config backup, plus new5558 staged failure/resume and missing-config controlled refusal preserving files. No delete/reinit or weakened exit gate supports the repair. This addresses the customer continuity risk of losing setup/data during recovery.

Scope is targeted bootstrap mechanism/development resume only, not final package or release. Customer does not claim general lost-secret recovery or final S3-A09/A11 PASS. The latest TechnicalDebt snapshot read still awaits actual repair review; resume requires its independent closure plus QA and majority of the fixed five. Optional BPMN remains after remaining operational gates. Existing live installs were not touched by this Customer review.

## Actual new targeted vote S3-RESUME-2b

Customer votes FOR exact sprint-03-jobs-resume-proposal-v2.md raw SHA256 `961E2B99F050B775D54047E8DD31A075B4BACEFC114DE6A93DA427CBA58D5D94`, recomputed after full actual read. No oldv1 vote is transferred. Read independent QA and TD actual closure/vote evidence: terminal callback-refusal3 and optimized HTTP8 support durable cancellation/failed snapshots before memory/watch publication; second restart preserves snapshots/results/IDs. Actual same153MiB corpus optimized startup9792/13683/11278ms and18 unchanged original object hashes support narrow optimized-path reopening without reset, data reduction or enlarged deadlines.

Customer judgement: repair protects truthful user-visible state and existing data; targeted resumption is justified. Debug-mode timeout and high scaling debt remain genuine, not hidden by release-mode success. Captured precrash state is Completed+Queued; running-at-kill is explicitly still mandatory. Migration process kill, connection faults, full-DDL PG replay and final exact-package/frozen QA remain gates before affected acceptance and optional BPMN progression. This is not final release/enterprise/general capacity acceptance. Existing live apps/data untouched by Customer.
