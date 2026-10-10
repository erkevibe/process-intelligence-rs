# Sprint 02 independent architecture / TechnicalDebt position

Council invitation: 2026-10-10 06:40:06 UTC. Eight-hour deadline 14:40:06 UTC; planning/control/setup count. This is an independent position before exact proposal, not a vote or product acceptance. Owner of this report: technical_debt. No production files or environment changed.

## Environment evidence and choice

Read-only command lookup found Docker CLI at its configured user installation; docker version returned no server and named-pipe dockerDesktopLinuxEngine not found. Java, psql, postgres, pg_ctl and initdb were not found in PATH or inspected conventional Program Files directories. This does not prove absence everywhere.

Real PostgreSQL is feasible without global service installation: official Windows download page links an EDB binary ZIP. Use a pinned supported x86_64 distribution, provenance/hash manifest, private .local binary/data paths, explicit loopback port and app-only role. Limit environmental diagnosis to 15 minutes; actual initialize/start/connect/transaction probe remains required. Do not start Docker Desktop or legacy Java recovery as an unbounded prerequisite. SQLite can only be an explicitly partial alternate delivery; it does not satisfy promised PostgreSQL R3.

Sources checked today: [PostgreSQL Windows downloads](https://www.postgresql.org/download/windows/), [initdb](https://www.postgresql.org/docs/current/app-initdb.html), [pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html), [row security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html). Official ZIP availability is evidence of a distribution route, not a successful local setup. PostgreSQL documentation warns that pg_dump is single-database and restored dumps execute source-controlled SQL; use only trusted project-generated snapshots and restore to an isolated database before adoption. Raw credentials/backups stay private.

## Feasibility and gates

Full historical R2 through R5 spans weeks and cannot honestly be accepted as complete in 480 minutes. Selected coherent slices can fit if optional modeling/calendar work is contingent on durable storage and authorization gates. Suggested portfolio: mandatory CSV mapping/normalization, transactional persistent logs/analysis/provenance, restart and backup/restore; small users/projects/memberships enforcement and durable job recovery; then one narrow BPMN round-trip and editing slice; selected filters/calendar only when their independent contracts and verifier fit the reserve.

Protect final 90 minutes for independent checks, recovery exercises, frozen source identity and delivery. Do not spend it on new modules. Environmental checkpoint 15 minutes, persistence/restart/restore before optional BPMN, cross-user denied-path tests before public multi-user claims. No averaged R2–R5 score may hide failed storage/RBAC gates. Oracle absent means compatibility unverified.

## Interfaces to fix before parallel implementation

- Storage owns persistent IDs (UUID or database sequence across restarts), schema version/migrations, source hash and normalization policy, optimistic revision, project/user ownership. Parsing/mining remains pure and does not know HTTP or credentials.
- Repository methods accept authenticated Actor and resource/project identity; authorize before reading details, export, graph, case list, job snapshots/events/cancel, model or backup. Never accept owner/user from request as proof. Existing R1 global current/log sequence cannot become a shared multi-user active-log pointer; current view is actor/session-scoped.
- One transaction publishes log, normalized data/analysis and successful job result state. A success response occurs only after commit. Memory caches are disposable and must not masquerade as durable state. Avoid holding std mutex across database await; define lock ordering and optimistic conflict responses.
- Durable job transitions use version/state compare-and-swap. Accepted cancellation and publication share a transactional decision. Restart converts interrupted running to explicitly interrupted/recoverable state; no fake completed and no indefinite running. Idempotent result identity prevents duplicate publication. One-worker local deployment is an acceptable declared bound; distributed exactly-once is not promised.
- CSV/XES share a normalized EventLog contract. Record mapping, separator/encoding policy, timestamp offset and equal-time tie-break order in export. Explicit source order versus timestamp order; invalid mapping/row returns context and preserves the last valid result.
- Backup bundle includes schema version, manifests/hashes, data and project/membership relationships needed for recovery. Test to an isolated destination; corrupted/wrong-version bundle cannot partially overwrite working data. Decide explicitly whether auth sessions and password hashes are restored or invalidated; they must not leak in public artifacts.
- BPMN subset has a closed allowlist and rejection rules; semantic ID/node/edge round trip is verified, not byte XML identity. No DFG renamed as causal BPMN discovery. A deliberately simple sequential/variant miner can be labeled narrowly and evaluated on fixtures.
- Calendar contract must state timezone, working intervals, holidays and DST handling; duration fixtures must be independently computed. Defer full calendars rather than silently treating UTC subtraction as business-time equivalence.

## Risk appetite and meaningful acceptance priorities

Medium portfolio appetite, high experimental appetite for optional UI/model slices, low appetite for durable publication, backup restore and authorization. Required evidence: real PostgreSQL create/read/update/restart; forced failure before commit leaves prior analysis intact; restore reproduces input hashes/counts; corrupt restore rejected; duplicate names isolated by stable IDs; second user denied direct resource IDs on all endpoints; viewer cannot write/cancel/delete; logout/session invalidation and cross-origin request handling; durable job interrupted/recovered/cancelled does not double publish; frozen R1 regression remains green.

Roles/permissions must be exercised with actual distinct sessions, not only service-unit booleans. Database RLS is an optional defense layer: owner/superuser bypass behavior must not be forgotten; app role cannot be a privileged owner relied upon for isolation. Full SSO, network hardening and enterprise readiness remain future unverified scope unless independently demonstrated.

## Findings and STOP boundaries

PLAN02-01 (high schedule risk): original ROADMAP estimates R2 days and R3–R5 weeks; eight hours must mean selected scenarios, not completed stages. Owner PM/root; closure exact scoped criteria and feature gates in proposal.

PLAN02-02 (high integration risk, not current debt): R1 web repository.current and sequence are process-global/in-memory. Reusing them unchanged after auth can mix user selections or IDs after restart. Owner root/backend; closure actor-scoped storage/query/current semantics with negative cross-user and restart tests before multi-user acceptance.

PLAN02-03 (high new correctness risk): cancellation publication now mutex-based; database addition can split terminal job state from saved analysis. Owner root/storage; closure single transactional terminal/result decision and interrupted-publication regression.

No new STOP now: no unsafe implementation has been observed. If actual unauthorized reads/writes, durable data loss, false success before commit or unverifiable recovery is demonstrated, STOP_DEBT applies to that path/release, with evidence, owner, regression and council resume. Two confirmed failures from one mechanism prohibit another equivalent run until the mechanism changes. Safe independent UI/docs work continues.

## SkillManager

Existing project-windows-gnu-toolchain skill reviewed; preserve direct LLD, exact host-DLL extraction and real import-library probe. Do not relearn already verified native-startup failure or broaden the skill to PostgreSQL before a real recovery solution has succeeded. Current future functions are missing roadmap functionality, not automatically debt. No new skill or production code created here.

## Actual S2-P1 vote

FOR exact docs/SPRINT_02_PLAN.md SHA256 2FA33BCCDDED13CB74C015F3FEA59D1EE0CA05A1B450C748051B321DCF81D7BB. Independently read the proposal and recalculated matching hash. This accepts the attempted sprint scope and mandatory acceptance contract, not product readiness or a guarantee all twelve will be finished in eight hours.

Plan closure: PLAN02-01 addressed by selected R2–R5 slices, every A01–12 mandatory and any miss partial, full historical stages not marked complete. PLAN02-02 addressed at contract level by stable resource IDs, actor-scoped current/view and server membership authorization across resource routes. PLAN02-03 addressed at contract level by atomic completed/result transaction and restart interruption handling. Implementation proofs remain pending and these closures do not constitute feature PASS.

Real PostgreSQL requirement, loopback and non-superuser application role, restore into separate project with passwords/sessions excluded, observed-variants miner limitations and fixed-offset calendar subset provide explicit boundaries. The last 90 minutes remain protected and the 15-minute environment probe bounds prerequisite cost. Partial delivery cannot be hidden by treating late features as optional. No new STOP now; actual loss/unauthorized access/false durable success will block its affected path independently of majority.

Existing R1 regression and fresh-source/browser/denied-route/restart checks must pass for product acceptance. This auditor remains independent of root storage/bootstrap author; no installation or production edit performed.
