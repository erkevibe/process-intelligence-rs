# Sprint09 C1 business QA — continuation checkpoint

Independent auditor `/root/qa_business_s9`; source `03f0ffd604651e0a0b6d29832f23cbb57ee6a3ea`, executable SHA256 `0DBC999D85A3196F820CBF870D26C38C99A16A1F68B1F75D9336D98F2FA7C362`. This adds actual final-candidate observations to `sprint-09-qa-business-c1-partial01.md`. No complete criterion acceptance or release vote is asserted.

## Actual imported-history boundary

`backupspooffinal01` and `importpolicyfinal01` both exited natively 0 on the fresh final fixture. The test created an empty source repository before exporting it; its independent digest oracle therefore did not round model floats. The ordinary authenticated restore accepted syntactically valid client-supplied actor/time/project/resource/revision/policy/outcome fields as history, preserved the historical fields, cleared policy/outcome and marked the event `project_backup_unverified`. The imported event was not exported as a trusted committed server event.

The authentic restore event's parameter digest was independently reconstructed and matched the original repository input binding and imported counts. Reimport and legacy history were accepted. Imported history claiming a trusted policy and unknown origin were refused with complete managed-state conservation. A subsequent genuine folder mutation remained distinguishable from the prior unverified import. The history UI heading was checked. These finite empty-repository tests do not establish full model backup or stock PostgreSQL recovery byte preservation.

Private complete inputs/responses/snapshots/results: `fresh/backupfinal01-*`, `fresh/spooffinal01-*`, `fresh/ipfinal01-*`, with actual phase process bindings in `fresh/backupspooffinal01.process.json` and `fresh/importpolicyfinal01.process.json`.

## Actual 512/513 retention and exports

`retentionfinal01` performed 1015 supported requests and completed actual auth and project boundaries at 512 and 513. It then exited natively 1 because the fresh Auth document omitted the empty deletions map and the harness indexed it before the witness loop. This finite failed attempt, complete streams and snapshots are preserved. No application mutation failed at that point and no runtime patch was made.

The distinct `retentionfinal02` harness corrected only the absent-map guard and used new artifact names. It continued from the actual stored totals and created, archived and permanently deleted real temporary projects to reach former-owner witness totals 512 and 513. It exited natively 0. The held clean deletion fault target was excluded and remained archived and intact.

`retentionexportfinal01` exited natively 0. This offline verifier compared complete exported arrays against their complete persisted boundary arrays for all six auth/project/witness 512/513 cases. Each total was exactly 512 or 513, retained count exactly 512, dropped count exactly 0 or 1, and order and all fields matched. Boundary snapshots are `fresh/auth-retention-{512,513}.state.json`, `fresh/project-retention-{512,513}.state.json`, and `fresh/witness-retention02-{512,513}.state.json`; corresponding full exports and native process proofs are retained privately.

## Safe handoff / still open

The owned HTTP3073 final process remains running. No process is stopped, no held-target rows are changed, and no database is removed. The primary auditor owns the coordinated L05 target fault/protocol stage. Earlier pending tokens have exceeded TTL and cannot by themselves prove deletion invalidation; they require a fresh coordinated issuance for that claim.

Independent-owner eviction isolation, final archive fallback variants/current revocation, actual deletion/fault/no-resurrection acceptance, interrupted-job recovery, restart, full stock backup/new restore including full 512-entry fields and owner isolation, model backup byte preservation, migrated legacy counterpart deletion and strict downgrade refusal remain open. Draft evidence is not transferred to final acceptance.
