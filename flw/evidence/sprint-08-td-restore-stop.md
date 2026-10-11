# Sprint08 TD — RESTORE01 source review

Independent auditor: TechnicalDebt / SkillManager. This is a source position, not acceptance or a resume vote.

## Proven failure and cause

QA reported a valid D2 backup restored with HTTP422 repository_corrupt. Original log_source used envelope version1 and original log_state contained no provenance; restored records instead had plain source and provenance in mutable state. The former manual normalized::split_repository field splitter produced precisely that incompatible representation. A manual test-only join could conceal the same error by reversing its own splitter rather than invoking the production decoder.

Impact: valid confirmed-import backups become unreadable after restore. Owner: Root runtime author; actual replay: independent QA. Publication and acceptance remain stopped for this cause.

## Addressed source mechanism

Read-only inspection at HEAD 3083a863ab96be3c1f2e536d0eefda66433387cd confirms src/normalized.rs split_repository preserves strict serde roundtrip, log/project identity, model validation and job-result links, then delegates to repository_v2::prepare(project, &repository, false). Repository persisted/deletion state is serde-skipped and defaults empty on deserialization, so this path encodes all records rather than applying a partial delta. Canonical prepare validates the header and document capacities, omits provenance from log_state, and stores it with immutable source_envelope_version1. Test join now calls production decode_log for every complete log record set and rejects duplicate/unconsumed records.

No decoder relaxation, schema change, production authoring or test execution by this auditor. Source mechanism is addressed; actual closure is PENDING.

## Required actual closure

Independent regression must preserve the original failed attempt and exercise a new exact candidate: confirmed import -> valid semantic backup -> restore -> restart -> load/export raw source and audit, exact source/hash/actions and actor-history provenance, folder/calendar/view/model/job catalog consistency. Include old plain-source backup compatibility. Check strict malformed envelope/state-provenance rejection remains. A successful helper-only roundtrip cannot replace actual restore/restart proof.

Only after QA evidence and an exact FLW targeted resume proposal may this STOP be closed. This does not grant final artifact acceptance or full R2–R5 completion. DISK01, native PowerShell5 full-backup UNVERIFIED, whole-service/miner oracle gaps and preview uncertainty/restart limitations remain separate.
