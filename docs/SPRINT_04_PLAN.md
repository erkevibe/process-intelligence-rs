# Sprint04 immutable plan S4-P1

Start2026-10-10T14:57:49Z; deadline22:57:49Z. Last90minutes21:27:49Z reserved for acceptance/delivery. Userauthorizes8h. Fivefixedseats Root/Customer/PM/QA/TD, independent positions/vote exact proposal before production development. Risk appetite low for persisted-data loss; medium implementation risk, full integrated candidate contour, lightweight drafts.

## Scope and architecture

Schema v2: project metadata, each log and each model in independently bounded records. Preserve auth, generic pi_kv, IDs, project CASrevision, jobs and atomic multi-record commit; update only changed records, serialize only changed heavy payloads. Keep Arc event/analysis sharing and avoid old-project serialization on job/view/model-only changes. Startup validates schema/checksum and bounded metadata, recovers interrupted jobs without reading entire payload corpus; project payload loading lazy. Validate persisted payload before exposure. Unsupported/future/corrupt schema refuses safely.

Migration from accepted0.3 database on isolated copy only: strict known baseline, explicit exclusion, split and compare records/full values, durable resumable stages with atomic visible project switch; interrupted migration may leave private shadow records but old accepted data remains intact until validated switch. Never increase production deadlines to force PASS. Old user apps/DBs untouched; no automatic0.3 downgrade of migrated database. Backup/recovery docs required. Explicit OFFLINE executable --migrate-storage performs migration using private PI_DATABASE_URL; normal recognizedv1 startup returns migration_required withoutDDL. Unchanged runtime15s and SQL5s/lock2s/transaction10s apply perphase, no total15s migration claim. Retain ALL old pi_kv repository rows unchanged/inert after v2cutover; forbid normal v2 reservedlegacy writes. No destructive cleanup thissprint. Stage records have knownsourceversion/checksum; existingstage exactvalue equality required, unknown/conflict refuses. Globalledger2 publishes only allverifiedprojects. Compositekeys project+kind+id; separate log_state/data/source/analysis/model records and bounded project header. Generic keys/auth remain unchanged. Projectbackup v1semantic format remains supported. V2firstprojectaccess loads payloads lazily; cachedwholeprojectmemory remains explicit measured residual, not generalmemoryscalingcompletion.

## Acceptance A01-A10

A01 Fresh v2, v1→v2 and idempotent reopen with schema checksums; unknown/future/checksum/table anomalies refuse without unapproved rewrite.
A02 Exact copied0.3 auth/session/projects/access/current/views/log/source/analysis/model/jobs/IDs/generic values preserve; original source DB unchanged.
A03 Actual process/backend interruption during migration; retry verifies no lost/partial-visible data or duplicate IDs; completed migration stable afterrestart.
A04 Delta writes: job/view/model mutation never rewrites unchanged log payload; staleCAS/partialbatch atomic refusal; result+terminal publication remains aftercommit.
A05 Previously capacity-refused SAME100kinput/SAMEsixlog corpus now stores separate log without aggregate JSONBoverflow; individual document guard retained; all old fullhashes unchanged.
A06 Numeric gates fixed before measurements: optimized candidate readiness <=15s each of3 samecorpus reopens; view/job/model mutation <=5s each of3 repeats; startup app WorkingSet maximum <= baseline0.3 maximum sampled appWorkingSet over3 runs. Also record firstprojectload/export/import and aggregateapp+PG samples separately with sampleinterval and processLifetimePeak distinction. No arbitraryspeedup target. Fixed baseline0.3 and candidate same-data runs: startup/time/RSS and job/view/model mutation costs measured with hardware/run/input hashes; report observed numbers, no blanket performance promise.
A07 API/browser core workflows and RBAC/foreignIDs/stalerevisions/cancel/Failed/Completed/restart regressions.
A08 Backup/newrestore exactv2 data/auth/schema and corrupted/existing-target negative guards.
A09 Frozen exact-source build/package/nativeWindows install independentQA/provenance; olduserinstallations preserved.
A10 Actual finalheadCI, Councilmajority, publish0.4 exactZIP anonymoushash/bytes and postpublication live independentacceptance.

## Delivery and cut policy

Root ownsproduction/filesintegration/plan/events and may delegate independent bounded productionmodules to nonvoting developer with exclusivefileownership; QA/TD never reviewtheir ownproduction; independentQA owns tests/evidence, TD source/debt audit, PM/Customer ownpositions. Do not claimSCALE01closed until measured delta-writing/startup tests satisfy the actual cause. Runtime whole-corpus memory may remainboundedmeasureddebt if lazyloading retainsprojects; declarelimits. If mandatory migration/data guard fails, repair before featureexpansion; release only acceptedexactcandidate. No newBPMN/oracle/features thissprint. Finish early ifscopeaccepted; neveruseunusedtimeforunspecifiedfeatures.

