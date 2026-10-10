# Sprint05 — demand-loaded resources and bounded cache (S5-P1)

Window: 2026-10-10 22:11:04 UTC to 2026-10-11 06:11:04 UTC (8 hours). Last 90 minutes, from 04:41:04 UTC, are protected for independent acceptance, recovery, delivery and reporting. Finish earlier if all mandatory gates pass. Runtime baseline: accepted 0.4 source f3a3ad46056e402e6891c9549b1505876fbb8e7e; EXE B4EA51E5264646709A1DDDB5686132D2662BB5275B271F4473A7B7592D58AAB8. Main at start c2029e154729dc2afbc2dff9a6e1992717d12b8d.

## Result and risk

Opening one journal must read and validate that resource, without retaining every journal/model in every visited project. Lists/navigation remain metadata-only. A single global clean cache retains at most 128 MiB charged resident estimate and 8 entries across projects and resource kinds. Successful mutations remain atomic and durable; eviction cannot remove data. Preserve schema2, accounts, sessions, resource IDs, user views, jobs, filters, calendars, models and full semantic backup/restore.

Risk appetite: medium implementation risk; low appetite for data loss, access leakage and false acceptance. High storage/concurrency consequence justifies one full integrated-candidate FLW contour. Drafts use proportional checks. Fixed Council: Root, Customer, PM, QA/ProcessLogAuditor, TD/SkillManager; independent roles and actual votes. User approval already authorizes execution and public delivery after accepted checks.

## Contract fixed before measurements

Authoritative complete log/model ID catalogs and small summaries are independent of resident payload maps. Dirty payloads and explicit durable deletions are distinct; a missing resident entry never implies deletion. Persisted comparison tokens/weak identities hold no strong heavy payload ownership. Commit uses existing project CAS and capacity checks; only successful SQL acknowledgement publishes/invalidate cache state. Failed CAS/write leaves previous durable state available.

Cache key contains project, kind, resource ID and exact stored record version tuple. Loads read a log's four components from one SQL statement snapshot; cache hits validate current versions and current authorization before disclosure. Per-user views are applied outside shared cached base values. Strict resource validation precedes publication. Unrequested corrupt payload may remain deferred; requested corrupt payload returns controlled refusal, never an old unverified replacement. Models are demand-loaded too.

Global retained budget is 134217728 charged bytes, maximum8 entries. Charge is a deterministic conservative in-memory ownership estimate: owned strings/vector capacities, structs, map/collection entries, Arc allocations and cache entry/key overhead; shared data/source counted separately conservatively. It is not physical RAM or serialized-file size. Oversized resources bypass retention, remain usable under active-operation admission, and never enlarge the retained budget. Eviction drops clean reusable ownership only. Active request/response values, loading validation buffers, jobs, uploads and allocator memory are separately scoped.

Global heavy HTTP operation admission: maximum2; immediate controlled503/cache_busy when unavailable, with permit retained through response-body completion/drop. Light health, navigation, status and cancellation remain available. Existing background job slots2, CPU1 and upload slots2 remain unchanged. Same-key loading is single-flight outside the global cache/workspace mutex; no SQL/deserialization under that global mutex. All error/disconnect paths release active reservations. Whole-project backup explicitly materializes one complete project under one heavy permit and consistent project mutation lock; it is a declared bounded project-sized temporary exception, not retained cache. Backup format remains complete and compatible.

Observable cache counters: charged bytes, entries, hits, misses, actual loads, evictions, oversize bypasses, active operations; safe resource/version identity and SQL-read counts in private logs. Never log cookies, passwords, raw input or connection strings.

## Achievable tasks and owners

1. T01 Root + Council: exact plan/votes, prospective task/event journal, private log ACL and baseline/corpus identity. Target first45 minutes.
2. T02 storage_developer (nonvoting): repository catalogs/light baseline, strict per-resource load and global resource cache. Exclusive src/repository_v2.rs and new src/resource_cache.rs; interface agreed with Root first. Target next2 hours.
3. T03 Root: snapshot/version SQL APIs, metadata lists, all route consumers/count guards, mutation/cache integration, heavy HTTP admission, complete backup. Exclusive other runtime files. Parallel with T02; target next3 hours.
4. T04 QA/ProcessLogAuditor: independent exact0.4 multi-project baseline, fixed manifest and gates before candidate measurements; live raw-log inventory; isolated fault resources. No production edits. TD independently audits ownership/deletion/locking and debt closure. Starts before costly runs.
5. T05 Root: meaningful draft regressions and one integrated immutable source/build/package0.5 candidate; no runtime changes after freeze without new candidate identity. Target by04:41 UTC.
6. T06 independent QA + TD + Customer + PM: frozen candidate acceptance and real exact-identity votes. Root resolves failures with a new candidate when necessary; final head CI, public immutable ZIP/checksum, anonymous download, fresh installed live0.5 and protected old-live verification.

## Mandatory acceptance matrix

A01 Compatible adoption: copied accepted0.4/schema2 data opens without schema migration; all old full resource values/IDs/jobs/auth/views/model semantics match. No protected original database mutation.
A02 Per-resource laziness: observed SQL/read/load counters prove lists don't fetch heavy documents and opening one resource doesn't fetch siblings. Unrelated controlled corrupt payload does not prevent healthy metadata/resource operations within this contract; requested corruption refuses before disclosure.
A03 Actual global cache: at every observable retained checkpoint bytes<=134217728 and entries<=8. Oversize bypass, same-key single-flight, active limit2, failure/disconnect release and concurrent other-project progress tested. No hidden heavy Baseline/workspace owner.
A04 Eviction correctness: full accepted03 six-log project copied into three deterministic independently owned projects with full values/semantics and mapped IDs. Fixed A→B→C→A multi-log traversal repeated three cycles exceeds cache capacity, shows actual eviction/reload, and verifies full export/value hashes. No shrinking the corpus.
A05 Writes and access: unloaded sibling record/version/hash preservation after views, filters, calendar, model save, jobs and eviction; stale CAS refusal; same IDs in distinct projects cannot alias; authorization checked on every hit and after role/membership change. Result+Completed remain atomic, Failed/null durable.
A06 Recovery: owned application and PostgreSQL failures, job cancellation/restart, exact unchanged old data and healthy legitimate subsequent write. Stop only verified owned new test processes. Backup/new restore preserves complete data despite unloaded resources.
A07 Fixed performance: same three full six-log projects, same traversal/order/input/host/warm-state with accepted B4 comparator. Freeze manifest and baseline numbers before candidate measurements. Three startup ready runs<=15s, three small mutation runs<=5s, first and evicted reload each<=15s on each of three repetitions. Candidate app working-set maximum across matched workload<=baseline matched maximum; final quiescent working-set maximum<=75% of baseline matched quiescent maximum. Report actual sampling intervals (target100ms), lifetime peak, app and owned-PG sums separately. No allocator reclamation guarantee, forced GC, smaller workload, changed timeouts or posthoc threshold changes. Cache budget is never advertised as RSS cap. Same17200026-byte100k input remains the large-input regression; admission/worker completion/export/load times are separate.
A08 Meaningful ordinary + applicable real PostgreSQL regression checks, exact frozen build/package/native start and PowerShell7.6.5 stock backup/restore/offline migration scope. No equivalent blocked native5 backup/security retry.
A09 Independent log/source/debt audit with actual exits and raw hash manifests; missing/truncated/disabled/not-in-run sources explicitly scoped. No universal error-free claim. Exact immutable candidate, majority votes and final-head CI precede delivery.
A10 Public exact0.5 ZIP/checksum anonymous verified against manifest; fresh live0.5 install and old3000/3010/3030/3040 + protected clusters preservation. User's final human acceptance remains separate.

## Stops, exclusions and fallback

STOP for data deletion/loss, cached access leakage, stale overwrite, retained-budget violation, protected-resource mutation, security bypass or false evidence. Two repeated same-cause failures require mechanism repair and independent regression before Council resume. Mandatory cache/lazy/recovery/performance gates cannot be silently cut to publish0.5. If unresolved by deadline, report partial work and keep accepted0.4 available.

No legacy disk cleanup, schema3, new BPMN/Apromore features, production-user migration, HA or full enterprise/parity claim. DISK01 and nativePS5 backup UNVERIFIED remain explicit debts. New private resources use pi_s5_* identities and new isolated ports/datapaths; old installed versions, clusters, sessions and user data remain untouched.
