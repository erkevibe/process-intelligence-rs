# Sprint05 TD draft audit — source only

This is an independent source review after actual S5-P1 adoption, not runtime acceptance or CACHE01 closure. No build, database mutation or production edit was performed. Reviewed current src/resource_cache.rs, repository_v2.rs, web.rs, platform.rs and storage.rs integration; this is a moving draft, not a frozen identity.

## Positive source mechanisms

Authoritative log_ids/model_ids survive unloaded maps. Header unions catalogs with explicitly present dirty resources and removes only explicit deleted IDs. prepare no longer interprets absent resident entries as durable deletes. mark_persisted clears lazy dirty maps only after SQL acknowledgement. Baseline holds Weak heavy identities and small log state, not strong EventLog/Analysis/model payloads. Four log parts are fetched in one SELECT snapshot; strict decode/filter/analyze/calendar/view and model export validation precedes publication. Cache entries are global, version checked on each hit, project/kind/resource keyed, charged before retention and bounded by bytes/count; oversize bypass remains usable. Same-key flight lock is independent of the global state mutex. Resource payload drops occur outside the global state guard. Workspace loading now reads metadata without holding its global map lock over SQL. get_log/get_model recheck current actor and apply per-user views outside cached base values. Commit invalidates only after successful write acknowledgement. Backup loads the complete repository under its project mutex and checks revision, so it does not serialize just cached members.

## Findings / pending fixes

### S5-TD-HTTP01 — HIGH — Root web integration — OPEN

Evidence: request_guard initially classified /jobs/{id}/events as heavy and attached a body-lifetime permit. job_events waits for future snapshots until terminal. Two normal long-lived job watchers therefore consume both heavy HTTP slots even when no payload is loaded, preventing ordinary analysis/navigation/export/model operations throughout long jobs. Parent acknowledged source issue and proposed excluding idle SSE from heavy admission; acquire only for actual Completed resource/render event and retain through pending payload consumption/drop. Closure: inspect that mechanism and independent two-watcher/other-request actual proof. No runtime failure was manufactured or claimed.

### S5-TD-HTTP02 — HIGH — Root response/worker ownership — OPEN

A response-stream permit alone is insufficient when request cancellation drops the handler future while spawn_blocking work continues. Proposed scoped AppState Arc reservation must be cloned into every HTTP blocking closure and response body, with last-owner release. It must not be retained by persistent workspaces, JobStore or transferred background jobs. Background transfers strip HTTP reservation only after independent job admission. SSE pending heavy strings must hold reservation until yielded consumption/drop, then release before idle snapshot waiting. Closure requires controlled disconnect with a still-running worker, immediate extra admission refusal, then actual release.

### S5-TD-AUDIT01 — MODERATE — Root request guard — OPEN

Initial cache_busy immediate return bypassed shared request ID/security headers and audit event. Parent is repairing the branch so common guards apply to controlled saturation responses. Closure: source plus actual early-refusal header/log evidence.

## Other source boundaries requiring candidate evidence

Weak identities are comparison tokens only; durable version checks remain authoritative. Reload track_log must precede mutation so expired identities do not spuriously rewrite unchanged heavy pieces. Failed commit must preserve original repository and cache. The current project mutex serializes same-project loads/mutations and can block light operations of that project while heavy validation occurs; other-project progress must be proved. The cache's global epoch may conservatively suppress publication after an unrelated project commit; correctness is safe but hit/performance behavior needs matched workload evidence.

Whole-project backup remains the declared project-sized temporary exception and existing 20 MiB downloadable backup boundary; no retained/RSS bound is claimed for this temporary materialization. NativePS5 backup remains UNVERIFIED; stock PowerShell7.6.5 operator scope remains explicit. CACHE01 stays OPEN until exact integrated-candidate resource ownership, eviction, access, recovery and fixed performance gates pass.

## Repair addendum — source verification, actual gates still pending

Independently re-read repaired web.rs/platform.rs paths. S5-TD-HTTP01 mechanism is addressed in source: idle job SSE is excluded from blanket heavy admission; Completed rendering alone obtains a reservation, clones it into the blocking worker and retains it in stream state alongside the yielded analysis event until next poll/drop. Terminal-with-no-result releases it; saturation produces a small saved-result notification without loading heavy payload. Two idle watchers no longer own HTTP payload slots by this source path. Actual two-watcher/concurrent navigation proof remains required.

S5-TD-HTTP02 mechanism is addressed in source: AppState contains an optional Arc owned permit; Platform.scope clones the root state, preserving it; HTTP blocking closures own scoped state clones. The response body shares the reservation. Disconnect cannot release a still-running state-owning worker reservation. Background job state explicitly clears this reservation after its independent job lease has been accepted; no reservation is inserted in Cached workspace or JobStore. Actual controlled disconnect/worker gate and release proof remain required. SSE next-poll boundary bounds application-owned event construction; this does not claim that transport buffers or client RAM are charged to retained cache.

S5-TD-AUDIT01 is addressed in source: saturation sets a refusal branch but returns through the shared request/security header and request_completed audit path. Actual rejection headers and raw event proof remain required.

Canonical mutation separation is now explicit: get_log_base tracks the canonical stored base without applying actor view; filter/calendar/discover use it. get_log applies and validates the actor view only for disclosure. This avoids persisting one actor's private selections/threshold as the shared log base. Candidate tests must still prove other actors' full view and sibling payload preservation.

No source acceptance closes these findings end-to-end. No build or database fault was run by TD. CACHE01 remains OPEN pending exact candidate gates; no additional mandatory source blocker identified in these repaired paths at this review point.
