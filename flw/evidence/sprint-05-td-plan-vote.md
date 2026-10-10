# Sprint05 TD plan vote — S5-P1

Vote: **FOR**.

Independently read the complete docs/SPRINT_05_PLAN.md and verified its raw SHA256: **0A0C5F8CB468F618ABD01403BDADE40D817A5E25F82428C94D981C21113480ED**. This is a new vote on that exact plan, not an inherited Sprint04 vote or release acceptance.

The plan addresses the initial TD objections: authoritative catalogs are separate from resident payloads; eviction cannot imply durable deletion; comparison tokens retain no strong heavy payload ownership; four log parts use a single-statement snapshot; current versions and authorization precede cache disclosure; immutable base payloads exclude per-user view state; SQL acknowledgement precedes publication. Global retained charge, active HTTP reservations and background job capacity have distinct explicit bounds. Oversize bypass remains usable. Whole-project backup is explicitly a temporary project-sized exception under one heavy permit, not a claim of bounded total RSS.

The fixed 128 MiB/8-entry retained contract and predeclared matched-baseline performance gates make the outcome falsifiable. Baseline manifests/numbers must precede candidate measurement. Weak-identity tokens must never be used as a substitute for authoritative durable versions or explicit dirty state. Body permits must remain held until body completion/drop, including error and disconnect paths. Existing durable result/terminal ordering and stale-CAS refusal remain mandatory.

Medium implementation risk is acceptable only with low data/access risk, protected original resources, independent integrated-candidate evidence and the final90-minute gate. The 8-hour window is tight; unresolved mandatory gates require partial delivery with accepted0.4 retained. This vote does not close CACHE01, certify memory bounds, approve a runtime candidate or transfer any historical PASS. DISK01 and nativePS5 backup UNVERIFIED remain outside this sprint.

Owner: independent TD/SkillManager. Production and databases were not changed for this vote.
