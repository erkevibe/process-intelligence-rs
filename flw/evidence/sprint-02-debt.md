# Sprint 02 independent debt / SkillManager audit

Owner: technical_debt; independent of root production and PostgreSQL bootstrap author. Read-only production audit; no production or environment changes. This file is audit evidence, not product acceptance.

## Initial observation

At first execution-phase snapshot, .local/logs/s2-pg-bootstrap01.log was absent and storage/auth production modules were not yet present. PostgreSQL/bootstrap checks are not-in-run or not yet observable, not passed. Existing R1 source and historical sprint01 events do not establish new durable/auth behavior. No STOP asserted from missing future implementation.

Root proposed dedicated synchronous PostgreSQL worker plus block_in_place wait. Advisory ENV-S2-01: Tokio block_in_place panics on current-thread runtime, including the default tokio::test harness. Prefer bounded worker commands with async oneshot replies; alternatively spawn_blocking offloads synchronous wait. Never hold std mutex across await. Do not change all tests to multithread solely to conceal an incompatible public path. This is a design risk until actual source behavior is inspected, not proven current debt. Owner root/storage; closure async server and independent current-thread HTTP tests complete without runtime panic. Source: https://docs.rs/tokio/latest/tokio/task/fn.block_in_place.html .

## Acceptance evidence needed

Bootstrap: upstream EDB URL/version, observed artifact hash labeled honestly (not independently publisher-signed), PE host/runtime readiness, loopback-only pg listen, private data/password ACLs, actual app non-superuser role query and transaction commit/read. Logging coverage stdout/stderr/migration/app/job/collector declared explicitly; no raw credential printing.

Storage/auth: stable IDs, actor-scoped queries/current views, transactional persist+job terminal state, conflict/CAS behavior, negative distinct-session access across every resource path, interrupted durable jobs recovery, isolated backup restore and corrupt-bundle atomic rejection. Seed/reset never overwrites prior user data to simplify a test.

STOP thresholds: observed unauthorized read/write, durable loss or falsely successful uncommitted publication blocks affected implementation/release. Two confirmed same-mechanism failures prohibit equivalent retry until repair and regression. Safe parallel independent docs/UI paths remain available. Full enterprise, oracle and future functions are not inferred from selected successful slices.

## SkillManager

Existing verified project-windows-gnu-toolchain knowledge applies to the local Rust setup. No PostgreSQL skill created until a costly/repeated issue has a genuinely tested solution. Existing missing PyYAML quick_validate limitation is tooling debt of skill-format verification only, not a product runtime failure.

## PostgreSQL/bootstrap and draft storage/auth/jobs review

Directly read s2-pg-bootstrap02.log: PostgreSQL18.6 server running, app-role BEGIN/CREATE/INSERT/ROLLBACK probe completes; current_user pi_app, rolsuper false. This is a real backend readiness observation, not full persistence/auth acceptance. Private .local ACL inspected without identity/secret output: inheritance disabled, zero inherited rules, one access rule. The bootstrap script alone currently relies on that preexisting private-directory setup.

storage.rs inspected: dedicated synchronous client thread, bounded64 command channel, parameterized SQL, optimistic versionCAS and Batch transaction. Commit precedes successful reply. All async consumers must wait via spawn_blocking/async response; inspection found no block_in_place implementation. Authentication stores SHA256 session-token keys, random salted Argon2 hashes and bounded expiring session entries; full denial tests pending.

S2-TD-BOOT01, moderate recovery design gap, owner root/Operations, open: setup-postgres.ps1 only creates database inside the branch checking whether pi_app role exists. A failure after CREATE ROLE and before CREATE DATABASE leaves subsequent retries skipping missing database creation. Closure: independently ensure role and database exist; test or meaningful actual rerun on healthy state plus documented targeted interrupted-init check. Not an observed data-loss incident; no STOP.

S2-TD-JOB01, high integration verification requirement, owner root/backend, open before integrated candidate: try_complete_with callback receives the prior running snapshot; integration must explicitly construct completed result/revision and atomically persist it with log. Accepted-cancel branch bypasses completion callback, so terminal Cancelled must be persisted separately; callbackerror creates memory Failed and needs honest durable recovery. Existing in-memory callback alone is not A07. Closure: current actual paths plus acceptedcancel/restart/completion commit-failure tests. Root is currently integrating; missing future writes are not automatically debt/STOP.

S2-TD-AUTH01, guard requirement, owner root/platform, pending: User derives Serialize including password_hash. Never expose this internal storage object in admin/user APIs, backup or templates; use Actor/safe DTO. No password hash exposure observed. Runtime centralized authorization and all resource endpoints still require negative distinct-session tests; source-only Auth helper success does not establish access safety.

Bootstrap archive pinned first-observed TLS artifact hash is labeled honestly in script. No publisher-signed checksum claim, no new project skill until actual costly recovery is validated. Earlier inherited pipe stall is historical; Start-Process Hidden pg_ctl wait repair is source-reviewed, not independently reproduced by auditor.

## Concrete platform integration review / singleton advice

Read current src/platform.rs and integrated web.rs. Central middleware scopes resources through membership-backed Actor, viewer rejects writes, resource lookups use project repository, current/view maps keyed by actor. Auth UI renders Actor/Project rather than internal User; no password-hash HTTP exposure found in inspected rendering. Storage/CPU work uses spawn_blocking. store_log retention removes orphan current/user_views/durable-job references. Successful completed snapshot is constructed and stored with log in one repository commit; cancellation outer path persists terminal state. Existing tests reported by root are not independently executed in this review.

S2-TD-CACHE01 (high, candidate blocker until bounded), owner root/platform: Platform and Auth cache state across requests. Independent concurrent Platform instances on same database can authenticate a logged-out token from a stale cache; writeCAS avoids lost writes but does not invalidate another process read/session cache. Recommended scope solution: acquire a PostgreSQL session advisory lease in Platform.open before auth/cache loading; reject a second Platform with explicit error, without constraining Database-only transaction tests. Lease must be held by the actual worker connection until last Platform owner/worker exits. A dropped listener with live workers is not a real restart. Database restart drops session leases: cached reads must fail closed on connection/lease loss, or else an old process can continue reading after a replacement claims lease. Mandatory regression: second instance denied, actual old instance shutdown then reopen allowed, expired/loggedout session denied, connection loss fails closed before cached reads. No concurrency readiness claim until this is demonstrated.

S2-TD-BACKUP01 (moderate/high restore contract gap), owner root/platform, open: backup endpoint serializes active queued/running jobs while restore validation rejects all nonterminal jobs. Application can emit a bundle that its own restore rejects. Closure: reject backup while active with explicit busy or make an explicitly interrupted consistent backup snapshot; corresponding active-job backup/restore regression.

S2-TD-RESTORE01 (high data-loss risk on unverified path), owner root/storage, open: restore preserves incoming numeric resource IDs while destination PostgreSQL resource sequence may be lower (e.g. backup from another initialized database). Later allocation can collide with restored log/model/job IDs. Closure: remap restored resource IDs using destination allocator plus every reference, or safely reserve destination allocation above all restored IDs; test foreign/high-ID restore into low-sequence database followed by new resources with old data preserved. Existing embedded project_id remains source project unless retargeted; keep source provenance distinct from current restored project identity.

These are source-supported candidate risks, not claimed performed exploit/data-loss tests. Root notified promptly. Safe ongoing implementation may fix the paths; new release acceptance remains blocked on their closure evidence. No blanket STOP over unrelated BPMN/UI development asserted.

## Latest draft source recovery review (not frozen acceptance)

Reviewed current Platform.open PG advisory lease, same-worker health gate in scope/health/SSE, and storage client without automatic reconnect. This bounds concurrent cache/session instances and makes backend loss fail closed. Read QA observation of own advisory backend termination: 3 checks passed (cached reads/health503 and controlled reopen200); no shared database reset performed. S2-TD-CACHE01 recovered for inspected draft mechanism; final frozen exact-source replay still required.

Restore allocation now loops until log/model/job ID is unoccupied in its project/resource namespace; this is a sufficient bounded alternative to global allocator reseeding for declared project-scoped IDs. Old IDs remain preserved and new resource avoids overwrite; read QA low-allocator restore report summary2PASS. Auth restore retargets embedded project_id inside the same batch transaction. S2-TD-RESTORE01 draft closure supported; require actual frozen regressions.

Backup refuses nonterminal durable jobs with backup_busy, bounds normalized download to20MiB matching restore, and heavy preparation runs spawn_blocking. S2-TD-BACKUP01 source fix verified; latest explicit active-job regression still pending per QA observation. Model write/import/restore paths apply full validation, JSON1MiB and serializable XML limits before commit. Save preserves original topology/node IDs/kinds/process ID and discovery provenance, allowing labels/positions only. Calendar uses checked offset/interval boundaries and limits weekday/holiday arrays; no new panic path found in inspected limits.

Setup now applies private .local ACL before credentials and independently ensures missing database after role creation, addressing S2-TD-BOOT01 design cause at source level; interrupted-init regression/frozen packaging evidence pending. Outer request guard applies request IDs/security headers/audit even to early rejection.

S2-TD-PACK01 high source-identity / false-acceptance risk OPEN before candidate. package-windows.ps1 presently validates SourceCommit format only and copies configurable executable without binding it to actual build source. HEAD equality or clean source alone cannot identify stale target binary. Closure: package exact frozen clean build or verify independently recorded build proof containing exact source SHA and copied executable hash; no production dirty differences; packaged hash/run test and content manifest checked on fresh extraction. Root notified. This blocks release identity claims, not safe ongoing draft implementation.

No full latest-source PASS inferred from older46test/browser stages. Final candidate freeze, actual full regressions and package build proof remain gates. No production edits made by TechnicalDebt.
