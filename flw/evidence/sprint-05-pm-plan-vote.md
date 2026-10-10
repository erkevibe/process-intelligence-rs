# Sprint05 — actual PM plan vote

Seat: PM `/root/pm_final`, separate from Customer and independent QA/TD. New vote; no earlier plan or release vote transfers.

**FOR S5-P1**, exact `docs/SPRINT_05_PLAN.md` raw SHA256 **0A0C5F8CB468F618ABD01403BDADE40D817A5E25F82428C94D981C21113480ED**. I fully read the proposal and independently recomputed this matching hash before voting. This authorizes its scoped implementation, not acceptance or release.

The plan addresses the observed CACHE01 mechanism: payload-independent catalogs, individual log/model snapshot loading, weak persisted comparison identity, clean global reusable cache and explicit delta mutations. Missing resident entries cannot imply deletion. Authorization/version checks on hits and per-user view separation preserve the access contract.

The fixed retained limit of 134217728 charged bytes and eight entries is a cache ownership contract, not a RAM limit. Conservative ownership accounting must be independently inspected. Oversize resources bypass retention; maximum two heavy HTTP operations and permits through response completion constrain request-held values. Background jobs/uploads remain separately limited and measured. Whole-project backup is a disclosed project-sized temporary exception under one heavy permit and a consistent mutation lock; it must not be described as a 128 MiB total-memory operation. These distinctions make the exception acceptable without weakening A03 or backup completeness.

A04/A07 fix three full copied six-log projects, traversal, repetitions and same 100k input before candidate measurement. Existing 15-second readiness and five-second mutation ceilings remain; first/reload each has a 15-second ceiling. Matched maximum working set must not exceed baseline, and quiescent maximum must be at most 75% of matched baseline quiescence. These are predeclared workload acceptance gates, not universal allocator/RSS guarantees. QA must freeze reproducible quiescent checkpoints and baseline provenance before candidate measurements; no corpus shrinking, timeout increase or posthoc threshold adjustment is allowed.

The scope is ambitious but coherent for eight hours because schema2 remains compatible and no mandatory data migration, cleanup or new domain features are introduced. Storage developer and Root have explicit file boundaries and dependencies; independent QA/TD protect durable writes, eviction, isolation and fault recovery. Preserve all old installs and real user data. Protect the last 90 minutes from 04:41:04 UTC; unresolved mandatory gates mean partial work with accepted 0.4 retained, not weakened release criteria.

Final build/native/backup/CI/public-download/live-preservation checks remain mandatory. DISK01 and native5 full-backup UNVERIFIED remain inherited debt; this vote does not close them, CACHE01, full R2–R5, or enterprise readiness. Final acceptance requires new exact-candidate evidence and votes.
