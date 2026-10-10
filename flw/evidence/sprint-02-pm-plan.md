# Sprint 02 independent PM position before proposal

Owner: `/root/pm_final`, existing PM seat; separate from Customer and QA. Invitation supplied by coordinator: 2026-10-10 06:40:06 UTC. Budget includes preparation, installs, tests and delivery through 14:40:06 UTC. No application changes made by this review, no council vote yet.

## Facts and scope boundary

R1 supplies serializable EventLog/Analysis, an in-memory repository, bounded jobs and tested local UI. There is no demonstrated durable storage, user ownership, BPMN model or calendar contract in the inspected modules. Original R2–R5 roadmap estimates days to weeks and includes legacy oracle and advanced mining. An eight-hour sprint cannot honestly be announced as full completion of those stage exit criteria merely by creating screens or endpoints.

Recommended interpretation to defend explicitly: eight hours delivers selected end-to-end slices covering **each of R2, R3, R4 and R5**, with separately named mandatory criteria below. Full-stage completion remains distinct. If the user requires complete original stages in this sprint, the discrepancy must be stated before coding; silently reducing scope is unacceptable.

## Proposed mandatory slice criteria

| ID | Slice | Verifiable acceptance |
|---|---|---|
| S2-A01 | R2 CSV mapping | Select case/activity/time columns and preview; quoted delimiter/Unicode rows supported; row errors reject import and preserve old result; equivalent CSV/XES exact counts match. |
| S2-A02 | R2 ordering | Explicit source or timestamp order, deterministic equal-time tie policy, missing timestamp policy and lifecycle policy included in export. Tests show distinct expected DFG for deliberately scrambled input. |
| S2-A03 | R2 persistence/list | Two differently identified logs with identical names survive actual process restart with exact input hash, counts and chosen view; corrupt/incomplete transaction does not replace prior committed state. |
| S2-A04 | R2 backup/restore | Export/reimport versioned backup to a new store preserves IDs/hashes/counts; corrupted/incompatible backup rejected before changing current state. |
| S2-A05 | R3 projects/ownership | Create project and associate logs/models; owner and role checks apply server-side to list, read, mutations, export, job/cancel and model routes. Two-user cross-project denial tests exercise known IDs. |
| S2-A06 | R3 identity/session | Real local login/logout and server-owned sessions; no client-supplied role trust; secrets excluded from exports/logs. Remote/shared deployment remains excluded unless separately secured. |
| S2-A07 | R3 job recovery | Persist accepted jobs and terminal result links. Real abrupt restart changes interrupted running/queued jobs to explicit interrupted terminal status or documented safe resume; never perpetual running or duplicate result publication. |
| S2-A08 | R4 BPMN slice | Explicit supported BPMN subset imports/views/edits/saves/exports; IDs, labels and supported control flow survive round trip. Unsupported semantics rejected visibly rather than dropped. |
| S2-A09 | R4 discovery slice | Named simple baseline algorithm produces a saved viewable/exportable BPMN model from fixed fixture. State its limits and test trace behavior on defined small corpus; do not claim Split Miner or Apromore quality equivalence. |
| S2-A10 | R5 filters | One case/variant predicate and one activity predicate have explicit retain/remove semantics, apply consistently to recomputed counts/variants/DFG/export, and preserve immutable source log. Manual fixtures distinguish filtering events from merely hiding edges. |
| S2-A11 | R5 calendar policy | Explicit timezone, working days/hours and interval endpoint rules; fixed cross-weekend and boundary fixtures yield independently expected business duration. DST or complex calendars are unsupported or separately tested, never implicitly claimed. |
| S2-A12 | Integrated delivery | Actual clean setup/start/restart; previous R1 regression checks; independent browser CSV→project→filter→model→export; negative ownership/restore tests; fixed SHA, screenshots and evidence. |

All twelve are mandatory for the **selected-slices sprint** completion claim. Dropping any yields an explicit partial result, not renamed acceptance. Original R2 oracle compatibility and R4/R5 advanced coverage have separate unverified status. Per-slice passed/failed/unverified and full-stage status must be published side by side; an average cannot hide security or durability failure.

## Eight-hour budget and gates

| Elapsed | Work | Gate |
|---|---|---|
| 0:00–0:30 | Council, defended scope, independent fixtures/interfaces | Exact mandatory list accepted before app coding |
| 0:30–2:00 | Durable transactional store and CSV/order contract | Restart and CSV equivalence early |
| 2:00–3:00 | Project identity/session/ownership, persisted job recovery | Two-user deny matrix and restart state verified |
| 3:00–4:30 | Restricted BPMN import/edit/save/export and baseline discovery | Round-trip corpus, unsupported rejection |
| 4:30–5:30 | Case/activity filters and narrow calendar | Manual expected results and source invariance |
| 5:30–6:30 | Integrated browser scenarios, negative/recovery tests | Candidate scope frozen; no independent stage PASS from isolated modules |
| 6:30–7:00 | Fixes and exact candidate | Independent QA/debt assessments |
| 7:00–8:00 | Clean replay, package, evidence and publication | No new features; report partial if criteria fail |

Owners should be assigned before shared-file edits. Root retains integration; independent QA owns fixtures and denial/recovery scenarios. Preparation/control cost belongs inside this budget. Current role reviews can run alongside safe planning, not application implementation before defended plan.

## Risks, options and recommendation

High: ownership retrofit across every existing route can create a false security claim if only project listing is protected. Mitigation: central authorization and exhaustive route/action inventory before role tests. Auth must not be advertised as enterprise SSO. Failure blocks R3 slice acceptance.

High: storage and job cancellation publication must be one coherent transactional boundary. Writing JSON snapshots as a fast substitute without atomic recovery evidence risks invalidating R2/R3 promises. Prefer a real transactional local store for this slice if PostgreSQL bootstrap is not proved quickly; record that PostgreSQL platform exit criterion remains incomplete. Do not label SQLite implementation as delivered PostgreSQL roadmap work.

High: unrestricted BPMN editor/import would exceed time and silently discard extensions. Use a named supported subset and independent rejection/round-trip corpus. Keep a baseline discovery quality statement separate from XML round trip.

Moderate: calendar semantics can consume the whole R5 slot. Use narrow explicit timezone/business interval policy with rejection of unsupported cases. Claim no Apromore calendar equivalence without oracle.

Option A, recommended: commit to these selected vertical slices across R2–R5 with fixed mandatory criteria and honest remaining original-stage checklist. Option B: preserve the full original stage definitions and report an eight-hour partial advance without promising all stage completion. Both are honest; presenting A as all original stages completed is not.

Review basis: current ROADMAP, R2_SCENARIOS, R1 specification context, src/domain.rs serializable contracts and src/jobs.rs in-memory job contract; coordinator's current sprint request. No application tests executed by PM and no future outcome asserted.
