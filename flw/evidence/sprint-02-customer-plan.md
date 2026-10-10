# Sprint 02 independent Customer planning position

Owner: /root/customer. Council invitation 2026-10-10 06:40:06 UTC, fixed five seats. Preparation, setup, controls and delivery count toward deadline 14:40:06 UTC. This is an independent position, not a vote or human acceptance. Read ROADMAP, R2_SCENARIOS, actual accepted R1 review/final evidence, sprint-02-pm-plan and sprint-02-td-plan. No production files changed.

## Scope and value

R1 already provides usable local analysis but loses data on restart. The first customer value now is trustworthy continued work: import working CSV, keep the source/normalization choice, return after restart and recover a backup. Projects and access rules should then protect this work; a narrow model and business-time/filter scenario make progress through R4/R5 visible. Eight hours can attempt selected slices of all four stages. It cannot establish completion of the original multiweek R2–R5 scope or enterprise readiness.

## Stable Customer requests

| ID | Fact and user problem | Proposal and acceptance | Priority |
|---|---|---|---|
| S2-C01 | Restart currently destroys analysis; new screens cannot compensate for loss. | Protect S2-A03/04: two same-name logs retain distinct stable IDs/source hashes/counts/view after real restart; interrupted write and corrupt restore preserve committed work. | P0 |
| S2-C02 | CSV exports differ in columns/order and valid timestamps need an explicit policy. | A01/02 must show mapping and preview, support quoted delimiters/Unicode, report row errors; source/timestamp order and deterministic ties are visible and included in export. CSV/XES equivalence is exact under the same normalization. | P0 |
| S2-C03 | Project identity can expose the existing globally current log to another user. | A05/06 require actual distinct sessions: list/read/export/case/graph/job/model/backup routes deny foreign known IDs; viewer cannot mutate or cancel; current log belongs to actor/session. Logout invalidates session. | P0 |
| S2-C04 | A real database is specifically proposed, but environment setup is unproven. | Probe initialize/start/connect/transaction/restart early. PostgreSQL PASS requires real use, not configured URL. If environment fails, explicitly partial R3; a fallback store is not PostgreSQL delivery. | P0 |
| S2-C05 | Persisted jobs can otherwise remain running or publish success twice after restart. | A07 checks abrupt restart, explicit interrupted state or safe resume, and exactly one linked result under scoped single-worker rules. Cancel/publication share one decision; source result commits before success. | P0 |
| S2-C06 | BPMN is more expressive than DFG and unsupported XML can silently lose meaning. | A08: declared subset and explicit rejection, semantic IDs/labels/control-flow round trip; saved edits reopen identically. A09 names its baseline algorithm and supports trace behavior on independent fixtures; no discovery equivalence claim. | P1 |
| S2-C07 | Hiding edges differs from filtering cases/events. | A10 shows the active predicate and its retain/remove semantics, recomputes counts/variants/DFG/export, preserves immutable source and provides a clear reset-to-source action. Fixture distinguishes event removal from case removal. | P1 |
| S2-C08 | Calendar subtraction without policy produces plausible wrong durations. | A11 exposes timezone/work intervals/endpoints, manual cross-weekend and boundary expectations. Reject unsupported DST/holiday policies rather than silently approximate. | P1 |
| S2-C09 | Many isolated passing modules do not establish coherent user work. | A12 verifies actual CSV → project → filter → model → export plus restart/restore and cross-user denial on exact frozen source; previous R1 regressions remain green. Report each slice separately. | P0 |
| S2-C10 | R1 loss warning is below tall panels and background benefit is implicit. | Close UX-C01/02 with a short storage-state warning near export/upload and a clear progress/cancel explanation. Replace Rust4PM implementation wording in visible note with current parsing-stage language (UX-C04). Keep Fit controls; do not auto-refit same-log filtering (UX-C03). | P2 |

## Feasibility, checkpoints and risk appetite

The PM budget is an aggressive experiment, not a confident delivery forecast: a new PostgreSQL environment, route-wide authorization and transactional jobs are together materially more difficult than R1. Protect a final 90-minute verification/recovery reserve as TD recommends. First prove database and persistence, then cross-user isolation, then modeling and R5. Interface owners and route/action inventory must be fixed before implementation; no route is exempt just because it predated login.

All selected slices may be declared mandatory for the sprint-complete claim, but their priority controls execution. If a gate fails, later safe independent work may continue; publication remains partial and the missing mandatory criterion is not retroactively renamed optional. Do not claim the full R2 stage without an oracle, or enterprise readiness from local passwords and project roles. Final fixed resolution must explicitly retain these distinctions.

Proposed overall appetite: medium; high for experimental model/UI breadth, low for durability, restore, permissions and truthful acceptance. Demonstrated cross-user disclosure, data loss or success before commit blocks affected delivery. Averages must never conceal these failures. Selected-slice BCR and original-stage completion are separate tables.

## Emotional perspectives

Requested nine perspectives from the separate PM/emotional agent. Pending receipt; Customer has not fabricated them and will append the actual attributed input before final vote.

Received actual PM /root/pm_final input: Joy connects the working graph to reopening saved work; Sadness highlights restart loss and durable backup; Anger asks known-ID denied tests for existing unowned routes; Fear asks atomic refusal of damaged restore; Disgust asks escaping against HTML labels; Anxiety asks honest interrupted state after crash; Envy asks slice versus full-stage status; Embarrassment asks explicit timestamp/lifecycle policies; Boredom asks preview and retained CSV parameters. Each is a fact/problem/proposal perspective, not a claim about the human's feelings. Customer incorporates these through S2-C01–09; no extra vote is attributed to the perspectives.

## Initial position

Support presenting a concrete selected-slices plan covering R2–R5, with the P0 gates and truthful partial outcome described above. No exact proposal vote yet. This representative role does not impersonate the human user's wishes or replace their final acceptance.

## Exact S2-P1 vote

Customer /root/customer votes FOR S2-P1 in docs/SPRINT_02_PLAN.md with independently calculated SHA256 `2FA33BCCDDED13CB74C015F3FEA59D1EE0CA05A1B450C748051B321DCF81D7BB`.

Read the full actual proposal. It retains all twelve mandatory criteria, actual PostgreSQL, route-wide server permissions with distinct sessions, restart/restore and atomic job publication, explicit CSV/BPMN/filter/calendar contracts, protected final90min reserve, low appetite for durability/access and partial verdict for any missing criterion. This addresses the P0 planning concerns. Explicit subset discovery and fixed-offset calendar do not claim legacy or enterprise equivalence.

Remaining limitation: the eight-hour estimate is aggressive; this vote accepts a measurable attempt and fixed completion definition, not a guarantee of success. R1 UX-C01/02/04 remain P2 implementation follow-ups; their closure is not demonstrated merely by this plan. Human acceptance is not impersonated, and product acceptance still requires actual independent QA/TD evidence on a frozen candidate. No production changes performed by Customer.
