# Sprint05 independent Customer initial position

Owner /root/customer, fixed separate Customer seat. Read current main ROADMAP, accepted04 report/debt. Start2026-10-10T22:11:04Z, deadline2026-10-11T06:11:04Z, final90min from04:41:04Z supplied by coordinator. No runtime/DB actions or vote; existing3000/3010/3030/3040 and protectedPG5433/5437/5438 remain untouched.

## Fact/value/risk

Accepted0.4 solves metadata startup and delta-write costs, but first project access loads and retains all its payloads. Multiple large projects can therefore accumulate memory even when the user views one log. The desired value is predictable repeated navigation and editing across large projects without reimport, lost selections or runaway resident cache. A cache bound is not automatically a process-RSS limit: in-flight jobs/requests, exports and allocator retention must be named separately.

## Proposed customer scenarios and criteria

| ID | Priority | Actual acceptance desired |
|---|---|---|
| S5-C01 | P0 | Strict copied accepted0.4 store/session→candidate preserves all auth/roles/IDs/source hashes/complete exports/filter/calendar/view/model/jobs values; no migration/data rewrite merely to enable lazy cache unless explicitly planned/proved. Existing user DB never test target. |
| S5-C02 | P0 | Open project/log list or one model without fetching/deserializing unrelated heavy log payloads. Access one log loads only the required source/data/analysis/state, validates before exposure and preserves independent related-record consistency. Observable query/record-read evidence distinguishes lazy loading from eager cache with quick timing. |
| S5-C03 | P0 | Deterministic bounded cache budget/count with visible declared units and eviction policy; visit several fixed large projects/logs beyond budget, then revisit first log. All exports/counts/current selection remain correct and evicted clean entries reload. Heavy retained cache bytes/count return within bound after request leases release. |
| S5-C04 | P0 | Dirty edits and accepted worker results cannot disappear through eviction. Commit/CAS succeeds before cache publication; failed/stale commit preserves prior state. Concurrent same-log read/edit and cancelled/running jobs with forced eviction do not publish stale/foreign or uncommitted values. |
| S5-C05 | P0 | Actor/project/log keyed cache authorization applies on every request including cache hits. Distinct owner/editor/viewer/foreign known-ID sessions prove no cached information leak, shared-model mutation or role-change bypass. Same resource IDs in restored projects cannot alias. |
| S5-C06 | P0 | Eviction/reload corrupt/missing/changed persisted-record scenarios fail clearly before exposure, without poisoning healthy worker or modifying source. Actual app/PG crash during controlled cache-active workload preserves terminal/results and all full durable hashes on restart. |
| S5-C07 | P0 | Freeze identical multiple-large-project corpus hashes before baseline/candidate runs. Record three navigation/revisit cycles, first load/export/import, actual process memory samples and cache accounting after each phase. Predeclare numeric cache/latency targets before measurement; report warmed/cold scope, sample intervals, lifetimePeak and app+ownedPG distinct. No smaller corpus, expanded deadlines or universal RAM claim. |
| S5-C08 | P0 | Exact-source/package/native Start + prior migration/backup/roles/jobs/model regressions and independent QA/TD; final CI, public fullZIPhash and new/old live installation preservation. Artifact pass and delivered status separate. |
| S5-C09 | P1 | Eviction is transparent: no user reimport/relogin or lost valid view. If a large in-flight item exceeds budget, user sees an honest controlled policy/error rather than silent data truncation or permanent blocked navigation. Documentation explains cache budget versus import/record/total RAM limits. |

## Scope recommendation

Prioritize per-log load and bounded clean-cache eviction plus measured independent workload/fault checks. No legacy deletion, BPMN/oracle expansion or unresolvedPS5 protection experimentation. Preserve version0.4 dataset/backup semantic compatibility. Plan must explicitly define active leases/pins and oversize item behavior; accepting arbitrary oversize cache entries would defeat the promised bound. Prefer no dirty cache authority: durable records authoritative and cache entries disposable after commit/revision validation.

Risk appetite medium overall, low for data/access/worker atomicity. Actual lost data, unauthorized cache exposure or unsaved success is STOP for affected path; no current STOP asserted from initial read. HighCACHE01 closure must be scoped to actual retained-load/eviction measurements, not merely configured limits. Allocator/RSS may remain a measured residual if logically bounded entries release while process memory plateaus; explain without fake proof of returning all physical RAM.

Await separate actual PM/emotional perspectives and immutable S5-P1. New actual vote required, prior votes do not transfer. Final90min protected; no spare-time unrelated features. Human final acceptance not impersonated.
