# Sprint05 — independent PM pre-plan position

PM `/root/pm_final`, separate from Customer and independent QA/TD. This is a position before an exact proposal, not a vote or acceptance. Window: 2026-10-10 22:11:04Z–2026-10-11 06:11:04Z; freeze/acceptance reserve begins 04:41:04Z.

## Facts, value and scope

The accepted Sprint04 report and roadmap leave CACHE01 HIGH open. Current `Platform::load` holds the workspace-map mutex while loading and validating an entire repository, then permanently retains it. `scope` loads that workspace before returning any scoped request. Consequently project listing/navigation can pay for unrelated log payloads, and opening more projects retains more memory. Separate schema2 records already provide the storage boundary needed for a narrower loader.

The achievable Sprint05 outcome is metadata-only project access, demand loading of one identified log or model, and a globally bounded reusable payload cache shared across projects. Keep schema2 compatible and avoid a mandatory migration if no durable representation changes are needed. Preserve strict validation before exposing loaded data, delta/CAS atomicity, project/user ownership, source/export equivalence, views and durable job semantics. Cache admission, eviction and load failure must never become persistence operations or silently discard a successful write.

## Suggested mandatory acceptance contracts

1. Project/log/model lists and ordinary project switching read only necessary metadata. A first log operation fetches that log's required records, not all logs/models. Instrument record-read identities in private evidence; unrelated full hashes and versions remain unchanged.
2. Declare the cache scope, accounting unit, numeric budget and oversized-entry policy before performance runs. Bound aggregate cached entries across projects, not one independent budget per workspace. Define pinned in-flight entries separately: explicit bounded concurrency/admission prevents a claimed cache limit being defeated by unlimited request-held Arcs. Single-flight loading and failure cleanup must not leave permanent reservations or poisoned entries.
3. Eviction/reload preserves exact source/data/analysis/model exports, IDs, filters and per-user views. Dirty writes commit before publishing cache changes. Stale CAS still rejects; cancelled/failed jobs and DB failures cannot publish orphan results or terminal states before durable commit. Metadata/job ownership must survive payload eviction.
4. Fixed several-large-project corpus and deterministic traversal exceed the selected cache budget and demonstrate actual eviction. Include repeated reload, parallel same-log reads, different projects/users, mutations while another payload is pinned, and active job plus cancellation/restart. Test corruption of an unloaded log: refuse its access before export without rewriting it; healthy unrelated access remains usable where the contract allows it.
5. Baseline and candidate use identical copied schema2 data, host and operation order. Freeze corpus hashes, cache settings, process identities, sampling interval and comparison thresholds before the candidate measurement. Retain the existing 15-second readiness and 5-second small-mutation ceilings as regressions; new first-load/reload latency and app-memory comparisons must have predeclared numeric thresholds based on actual baseline, not retrofitted passing values. Report startup, first access, repeated access, post-eviction plateau and lifetime peak separately. Own PostgreSQL sampled aggregate is separate; no guaranteed OS RSS reclamation merely from logical cache eviction.
6. Same existing six-log plus 100k-event scenario remains Completed with original heavy hashes unchanged. Browser/API/RBAC/jobs/backup/new restore and exact native package smoke provide targeted regression coverage. Exact frozen artifact, CI, anonymous public download/hash and read-only preservation of all existing installations remain final delivery gates.

## Owners and dependencies

Root owns loader/cache architecture, affected route integration, storage consistency and packaging. QA independently freezes the workload and performs correctness, failure and performance measurements; TD reviews budget accounting, pinning/concurrency, lock lifetimes and cause-specific CACHE01 closure. PM owns requirement/value mapping and operator-facing limits; Customer independently checks the navigation and failure experience. No PM production edits are authorized here.

Agree loader/persistence interfaces and obtain the baseline early; do not begin unrelated features while those are unresolved. Metadata display may require small retained display summaries, but avoid silently introducing an unplanned durable migration. Models need independent demand loading too, otherwise a whole-model collection merely moves the memory debt.

## Cut and stop rules

Protect the last 90 minutes. If the bounded cache and correctness/fault gates are not stable by freeze, do not publish a nominal memory improvement or lower mandatory criteria; retain 0.4 as accepted delivery and report Sprint05 work as unfinished. Optional refinements stop before mandatory measurements and recovery. Two confirmed failures with the same cause require mechanism repair and independent regression, not an equivalent repeated run. Any data-loss, isolation, ambiguous commit or unbounded pinned-work counterexample blocks affected acceptance.

No legacy-row deletion, schema cleanup, new oracle/discovery/BPMN features, shell compatibility expansion, security bypass, or migration of real user databases. Preserve HTTP3000/3010/3030/3040 and their clusters. CACHE01 can close only in the measured workload and defined cache contract; full enterprise capacity remains outside this sprint. Disk duplication and PowerShell5 backup UNVERIFIED remain explicit inherited debt.

FLW cost review: one integrated candidate and focused independent audits protect durable data and truthful memory claims. Draft edits do not need repeated full Council freezes. Evidence must distinguish captured, missing and sampled scopes; neither sample peaks nor empty logs certify an absolute memory limit.
