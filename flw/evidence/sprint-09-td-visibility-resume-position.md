# Sprint09 TD independent visibility repair position

Position, not a Council vote or release acceptance. Actual review UTC: 2026-10-11T11:38:07.3007957Z.

Read the complete visibility01.result.json and current C1→draft C2 production diff. Actual C1 diagnostic shows one admin connection PID24516 with backend_type=client backend to pi_admin, but backend_type=null to pi_app; the old predicate evaluates null and omits that connection. Both complete PRE/POST hashes match; no cleanup CLI ran in this diagnostic. Existing writer refusal test remains a failed expectation, not cleanup_busy PASS.

The narrow draft predicate accepts client-backend OR NULL as busy, scoped to current database and excluding its own PID. This addresses the measured visibility omission without pg_monitor, extra privileges, or timeout changes. Unknown background connections may conservatively refuse; that is preferable to silently accepting unknown activity. Cargo changes only own version 0.7.0→0.7.1; dependencies unchanged. No other production change observed in this diff.

Recommend targeted resume only after an exact immutable proposal and new Council votes. This is source-level causal approval, not actual repaired-runtime closure. No C2 destructive operations before that decision. Exact new build/package identity and independent current-binary cleanup matrix, all C01–18 and F01–03, complete unreduced historical corpus, C05 identity/privilege, C02/C18 and business regression remain required. C1 results are historical; unchanged source may support review but cannot replace mandated replay.

Mandatory repaired-runtime regression: same cross-role admin connection, actual NULL visibility, controlled cleanup_busy refusal before mutation, complete source/restore state conservation. Test source and restore separately, idle foreign admin as well as active writer. Preserve all original failures. Deadline16:55:38UTC is not a waiver; unfinished mandatory proof means partial/defer, no public promotion.

Residual boundary: an activity snapshot is not an eternal prohibition on later connections. Advisory/table-lock and final transaction checks retain their separate responsibilities; this patch makes no general concurrency isolation or HA claim. No production/test/data/process changes by TD.
