# Sprint05 TD prefreeze source position

Scope: proportional moving-draft review, not final candidate acceptance or cause-specific CACHE01 closure. No runtime build or database mutation performed by TD. Source hashes read during review:

- resource_cache.rs 0B7B696B1729810B6B6403A2BA955FE8F2DC091395C242A516E08C96DB052A0F
- repository_v2.rs 1A1E7F873AAD6C970F241D2BE182FA37D8E02920B5622063C6FB95305D5A8669
- web.rs C8B678B1BD457F95A8CC55266D72E79B897AE0F9EE648F0F1B54085EBBF5C6A5
- platform.rs 6F1455F409A2B7564D2ED6F3C392DE67E46FB09FDF01379478D9E2FF46907B17
- storage.rs 0E4A10CCC9D85DB168EFEAD3E46C4618D7784C1D85758B6E41288234E291BB44

## Position

No additional mandatory source blocker identified in reviewed ownership/cache/repository/admission paths. Proceeding to integrated compilation and eventual exact freeze is reasonable; this is not a vote for an artifact. Earlier findings and source repair history remain in sprint-05-td-draft-audit.md.

Baseline LogToken holds small serialized state plus Weak data/source/analysis; model tokens are Weak. Weak allocation headers can remain but do not keep underlying vector/string payloads alive. Lazy mark_persisted clears dirty payload maps after acknowledgment. Complete catalogs survive resident absence; only explicit deletion sets produce SQL deletes. track_base occurs before a mutation to avoid rewriting unchanged heavy fields solely because an old weak token expired. Cache invalidation follows successful project write; project CAS remains authoritative rather than pointer identity.

Retained Resource::Log now holds Arc<StoredLog>, avoiding cloning all filter/calendar metadata under the global cache mutex. Heavy read/decode/validation happens under a resource-specific flight mutex, outside global cache/workspace mutexes. Flight registry has a finite64 bound and weak lifetime pruning; flight results have weak heavy ownership. Four resource components are fetched from one statement snapshot, strict source/filter/analysis/model validation precedes return, then record versions are rechecked. Current authorization is checked in resource access and again on each request. Private actor views never become cached base or canonical filter/calendar/discovery input.

Accounting covers each reviewed owned payload string/vector capacity and its element structs: event logs, cases/events/lifecycle, analysis nodes/edges/variants/caseIDs, filter lists, calendar arrays and model node/flow/waypoint fields. Arc headers, allocation overhead and cache/key/version/map allowance are conservatively charged; shared source/data are counted separately. Saturating byte charge and admission-before-insertion enforce the declared estimate/count boundary. This is a deterministic retained ownership estimate, not a proof of physical allocator/RSS consumption. Temporary validation clones, active outputs, jobs, uploads, small persistent metadata and backup materialization remain separately scoped.

Authentication/role rejection precedes heavy admission; admission precedes project SQL scope. AppState Arc permit accompanies blocking HTTP closures and body, while independently admitted background work strips it. Idle SSE has no heavy lease; Completed rendering receives a lease through worker/event construction and next-poll/drop. Common headers and request audit apply to saturation.

## Actual draft evidence read

Read .local/sprint05/qa/draft02/admission-report.json in full: scope DraftACE6 only, two checks PASS. A disconnected blocked worker kept reservation; third heavy request refused503/cache_busy in2.6854ms while the owned SQL gate was still blocked. The report also states safe headers and unauthorized403 first. After gate release, active operations0, legitimate export200, retained charged133150554bytes/2entries below134217728/8. These observations support the repair mechanism on that draft only; they do not prove final frozen SSE, whole traversal, all counters or all ownership paths. Parent-reported compile/clippy exits were not independently re-executed by TD.

## Frozen acceptance still required

Two real idle SSE watchers plus ordinary navigation; same-key concurrent single-flight and failure cleanup; every observable retained checkpoint; oversize bypass; unloaded sibling/full hash/version preservation across all mutations and eviction; authorization changes on cache hit; stale CAS refusal; complete backup/restore; actual owned app/PG failure; matched fixed performance and exact source/binary/package identity. Counter/report evidence must distinguish retained ownership from pins and working set. Do not transfer draft PASS to final source.

Residuals unchanged: project mutation mutex may serialize same-project requests; global epoch can conservatively suppress publication after unrelated writes; allocator reclamation and aggregate memory guarantees are not claimed. Whole-project backup is a declared bounded project-sized temporary exception. DISK01 and nativePS5 backup UNVERIFIED remain visible. No closed enterprise/parity or universal clean-log claim.
