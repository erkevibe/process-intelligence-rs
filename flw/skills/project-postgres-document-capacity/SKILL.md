---
name: project-postgres-document-capacity
description: Review this project's whole-document PostgreSQL JSONB capacity, accepted-job metadata reserve and controlled refusal regression. Use when changing repository persistence, job admission or serde_json numeric features.
metadata:
  origin: FLW-SkillManager
  source_problem: S3-QA-CAP01 / S3-TD-CAP02
  verified: 2026-10-10 / cap03-regression05 / capacity-batch01
---

Keep whole-document capacity refusal before queue/SQL. A PostgreSQL JSONB container has a28-bit offset/length limit; serialized JSON text length alone misses binary headers, entries, alignment and numeric expansion.

Current verified estimator traverses Value once: UTF8 key/string bytes; container7 bytes (4header+up to3padding); array4 bytes perentry; object8 bytes perpair; default finite serde i64/u64/f64 number32 bytes. Total-tree upper bound also bounds subcontainers. Check unified locked serde_json feature tree before relying on number32: arbitrary_precision invalidates the finite-significand premise. Treat a change in representation or PostgreSQL format as a reason to revalidate, not a license to raise limits.

Current hard budget268369920 reserves64KiB below2^28. New repository payload mutations and new queued-job admission use266272768, leaving2MiB for already-admitted progress/terminal and startup interrupted recovery. Preserve this distinction across model/filter/calendar/view/restore paths. Existing historical payload above lower budget may still finish/recover within hard budget; a blanket lower write cap can brick it. Bounded two-active-job leases, eight terminal snapshots and fixed runtime error strings justify ordinary metadata headroom; do not claim an unexecuted adversarial reserve-exhaustion experiment.

Validate every batch document BEFORE sending any write. Controlled project_capacity must not set the storage-unavailable failed flag. A rejected result never replaces the previous repository. Accepted background failure persists Failed/null before memory/watch publication; synchronous/admission refusal returns413. Count ceiling8 logs does not promise8 maximum-sized logs fit.

Verification after changing this mechanism: retain the unchanged large database and overflow-causing input; observe durable project_capacity failure/null, original complete-log hashes unchanged, health/export200, subsequent legitimate write, cancellation idempotence and restart-identical terminal snapshots. Independently test a batch with first small/second oversized document: neither written, same worker healthy and later write succeeds. Keep failed verifier attempts and superseded artifacts; use exact new binary hashes for final acceptance.

Verified Sprint03 draft cap03 EXE0BFBF697B3A29AE1357FF13EAD049F0E3C2BB70F3EE40C65CE4F356D9A0B9D77: unchanged204725604-byte project and same100k input actual4PASS; independent realPG batch1PASS. Evidence: flw/evidence/sprint-03-debt.md and sprint-03-qa-capacity-regression.json. This is controlled capacity repair, not scalable storage architecture; high SCALE01 remains open. No global installation or permission expansion.

Primary format sources:
- https://raw.githubusercontent.com/postgres/postgres/REL_18_STABLE/src/include/utils/jsonb.h
- https://raw.githubusercontent.com/postgres/postgres/REL_18_STABLE/src/backend/utils/adt/jsonb_util.c
