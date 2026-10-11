# S8-P3 proposal: explicit retained legacy cleanup (DISK01)

Status: design only, NOT accepted or implemented. This document does not authorize a database operation. The current S8-QA-RESTORE01 STOP (D2 restored original project returns repository_corrupt 422) must be resolved and independently verified before this extension can enter an acceptance candidate. No database was connected, restored or modified for this design. Protected installations remain outside its scope.

## Purpose and source findings

Remove inert `pi_kv` rows whose keys are exactly `repository/<project_id>` after schema-2 migration, with a verified recoverable full backup. Preserve every other managed value, version, identifier and migration marker. Removal saves logical duplicate storage; PostgreSQL MVCC deletion does not promise immediate operating-system disk shrink. No automatic VACUUM FULL, schema alteration, recreation, or deletion of installations is proposed.

`migration_v2.rs` binds each retained row to `pi_migration_v2.source_version`, `source_sha`, and the exact normalized DDL checksum. Its source hash is Rust `sha256(serde_json::to_vec::<Value>(value))`. SQL `jsonb::text` hashing cannot replace that eligibility proof. Current normalized headers and records may have legitimately changed after migration; equality to the old repository payload would reject valid installations.

For an already-ready ledger `[1,2]`, migration delegates to existing schema validation. `normalized::validate_ready` validates marker shape/checksum, without requiring the retained legacy row. Thus deleting those rows appears compatible with schema 2, without a new schema version or rewritten ledger. This is a source inference, pending independent actual startup, migration-no-op, and complete recovery tests. No downgrade compatibility promise follows from it.

## Operator contract and ownership

Proposed new wrapper: `tools/cleanup-legacy.ps1 -Mode Preview|Apply`, accepting an existing `-BackupFile` plus its existing manifest, source private config, a NEW `pi_restore_*` target, private `-PlanFile`, and, for Apply, `-ConfirmPlanSha256`. If a separate restore cluster is supported, it requires its own explicit private config. Source and restore credentials go through private child environment/config, never command arguments, plan, public output, or tracing.

Preview invokes the existing stock `database-backup.ps1 -Mode Restore` on a new target. It does not create a backup automatically or restore over an existing database. This creation of an isolated restore database is an explicit operator action, shown before execution. Failed or interrupted restore leaves that new database for inspection; the wrapper does not delete it. The archive and manifest must be complete, match bytes/size/hash, and reside in the private installation directory. Existing backup manifests lack actual identity and restoration evidence; they alone cannot authorize cleanup.

Proposed native options are `--cleanup-storage-verify` and `--cleanup-storage-apply`. Verify receives private source/restore DSNs, archive identity, and an explicit plan destination. Apply requires the exact plan SHA and archive SHA, independently recomputes the proofs, and never trusts a caller-supplied success receipt. Existing `--migrate-storage` retains its behavior. Unknown flags and incomplete arguments refuse before mutation. No HTTP cleanup route, startup cleanup, scheduled cleanup, or implicit retry is added.

The cleanup developer owns a new pure/native cleanup module, focused tests, and wrapper. Root owns shared CLI/module exports, packaging and storage-document integration. QA and TD independently validate the exact frozen candidate and full test corpus; the author cannot accept this work. Calendar/folder authorship confers no cleanup acceptance vote.

## Actual identity, offline ownership and complete comparison

Use live server identity `(pg_control_system().system_identifier, pg_database.oid for current_database())`, with database name as a diagnostic field. Different URL strings are not evidence of different databases. Equal identity pairs refuse, including aliases; different database OIDs in the same cluster are acceptable. A copied physical cluster with the same pair is conservatively refused. If the operator role cannot obtain identity, refuse; do not fall back to URLs, grant privileges, or change server security. The existing privileged backup operator configuration supplies access where available.

Keep the live connections until completion. Require the pinned PostgreSQL version and UTF-8, writable non-recovery databases, known current schema/DDL checksums, and no unsupported managed-table triggers/rules/RLS. Take both existing session advisory application leases (`5785256839849804116`) in deterministic actual-identity order, with try-lock refusal. Never terminate an application automatically. Source and restored database must both be offline; verify absence of pre-existing other application writers. Normal new application connections respect this lease, but arbitrary privileged SQL and previously connected generic writers are outside that guarantee and must be excluded.

Compare all rows, keys and versions in `pi_kv` (including auth, generic keys, and retained repositories), `pi_projects`, `pi_records`, `pi_migration_v2`, and the schema ledger including applied timestamps; compare resource sequence definition, last value and is_called. Use deterministic ordered, length-framed tuples and complete JSON values, not counts, IDs, selected projects, or sampled fingerprints. Preserve the source and restored snapshots' complete equality before cleanup. Do not start Platform or login against the verification copy: authentication sessions and job startup can mutate it. Any functional recovery check uses another new restore.

Two explicit hash domains prevent confusion. Legacy eligibility uses the exact existing Rust serialization/hash (a streaming writer may be used only after proving identical bytes). Whole-state fingerprints use complete canonical server JSONB text hashed on the same pinned PostgreSQL engine, plus all non-JSON fields. That SQL hash is a state comparison, never a substitute for migration source_sha. Verify current managed data with side-effect-free decoders; opening a Platform to validate it is prohibited.

The plan contains format/build version, schema checksums, archive SHA/size, actual identities, full managed fingerprints, counts, exact candidate keys with source versions and marker fields, and expected removed bytes. It contains no data payloads, credentials, usernames, tokens, or session bodies. Protect it with the existing private ACL convention. A fresh restore binds the actual archive to actual recovered values. Unknown legacy rows, any mismatch, malformed stage, missing current project, or incomplete/future schema refuses the whole operation rather than silently cleaning a subset. Markers without retained rows are valid already-cleaned state.

## Final transaction and interruption behavior

Apply reacquires both offline leases and revalidates plan/archive/identity. Begin a fresh READ COMMITTED transaction and acquire managed table locks in deterministic order before the first data snapshot: source SHARE ROW EXCLUSIVE, restore SHARE. Recompute full managed fingerprints, exact keysets, versions and marker bindings under those locks. The final full-value SQL fingerprints must equal the values whose Rust legacy eligibility was already checked; therefore a changed same-version legacy value cannot escape revalidation.

Sequence nextval is nontransactional and table locks on managed tables do not freeze it. Offline ownership and exclusion of other writers remain mandatory; never claim that the table-lock set proves absence of arbitrary administrator sequence changes. This is an explicit risk boundary.

Perform one parameterized DELETE of the exact verified candidate keys, with source-version guards. No broad LIKE deletion. RETURNING keys/versions must equal the entire plan set or roll back. Recheck every noncandidate managed value/version and sequence, and verify the expected post-state fingerprint obtained by removing precisely those keys. Leave markers, auth, headers, records, ledger and sequence unchanged. Commit once. No audit-table or marker mutation is hidden in this operation; a durable database cleanup journal would require a separate contract/schema decision.

Before commit, connection/process failure rolls the transaction back. After an uncertain commit acknowledgement, return `cleanup_outcome_unconfirmed`, reconnect read-only and reconcile complete expected post-state against the archive/plan; do not automatically retry deletion or claim rollback. A receipt-write failure after a known commit is reported separately. Repeating on a valid schema with no retained legacy rows returns explicit empty success with zero database writes. An empty repeat alone does not prove the outcome of an earlier uncertain operation.

Keep the verified restore untouched. Recovery is an explicit operator restore into another NEW database and selection through Start, using the current compatible binary. Never restore over source, reinsert old legacy payloads into an active normalized database, or silently switch the application's database.

## Bounds and feasibility gate

Proposed cleanup-specific bounds: at most 10,000 managed rows, key at most 512 UTF-8 bytes, private plan at most 4 MiB. Existing document hard limits remain unchanged; inspect/hash one legacy row at a time, never materialize every project payload simultaneously. Extra generic rows beyond the cap cause controlled `cleanup_limit` refusal without altering ordinary runtime admission. Hash full JSONB values on the server and return bounded digest inventories; no sampled or truncated comparison.

Preserve existing session budgets: SQL 5 seconds, lock 2 seconds, transaction 10 seconds. Initial backup/restore and read-only eligibility work happen outside the final transaction, with an explicit operator-visible duration bound. If the unreduced full corpus cannot complete the fresh locked full comparison, DELETE and postcheck inside those existing budgets, DISK01 stays OPEN and this extension is excluded. Do not increase timeouts, reduce fixtures, replace full checks by versions-only, or postpone checks until after commit to manufacture acceptance.

The stock dump is a full database archive, but not a backup of cluster roles/global configuration. Stock restore deliberately maps ownership to pi_app and excludes restored owner/privilege commands. Complete managed-state equality does not establish equality of arbitrary custom user objects or ACLs; this extension must reject unsupported extra application objects or scope its recovery claim explicitly to the supported managed schema. No assertion of generic enterprise disaster recovery is implied.

## Manual future corpus and phase gates

Freeze literal expected outcomes before implementation:

1. Full existing old-0.3 dump, restored to a new private database and migrated, with every project/log/model/auth/generic row retained. Make legitimate normalized edits while old legacy stays unchanged; cleanup still succeeds when marker binding remains exact. Record actual complete counts rather than assuming a historical subset.
2. Valid full backup -> fresh restore -> full equality -> exact all-candidate deletion. Every noncandidate full value/version and sequence remains equal; current startup, exports, RBAC and existing identifiers survive. A separate full restore reproduces the pre-cleanup complete state.
3. Same database under different URL aliases refuses. Different OIDs in one cluster can pass. Equal physical-clone identity and inaccessible identity privileges refuse safely.
4. Corrupt/swapped archive, wrong manifest, stale plan, changed source or restore value with the same version, and restore login/session mutation all refuse with zero source changes.
5. Wrong source version/hash/marker checksum, unknown legacy key, missing project, ledger 1, malformed stage or future schema refuses the whole batch.
6. Active lease in either database, other writer, table lock contention and timeout produce controlled refusal with no source mutation.
7. Actual native process/backend interruption before DELETE and observably after DELETE but before COMMIT leaves the entire original state. Independent evidence must establish the latter boundary; a parser/unit test alone is insufficient. If that boundary cannot be observed safely, leave it NOT-IN-RUN and do not accept the cleanup. No hidden production sleep/fault flag is proposed.
8. Lost commit acknowledgement produces explicit uncertainty and read-only whole-state reconciliation. Exact empty repeat is zero-write success. Full rollback restore into a new target restores all original retained rows and latest normalized/auth state.
9. Full caps/budgets and actual raw stdout/stderr/exit/identity/hash evidence are measured on new owned PostgreSQL resources, never protected installations. QA and TD bind results to exact source/executable/package bytes.

Gate 0: resolve current restoration STOP. Gate 1: invite all five Council roles and vote on the exact proposal SHA; no implementation before accepted scope. Gate 2: freeze manual corpus and assign nonauthor QA/TD, then implement isolated files and Root integrations. Gate 3: independent full recovery/atomicity/bounds tests on new resources. Gate 4: exact frozen packaged candidate passes before the 08:12 freeze, preserving the final 90-minute reserve and 09:42 deadline. Optional cleanup cannot lower any already accepted S8 criterion; failure or insufficient time leaves DISK01 OPEN.

## Primary references

PostgreSQL documents [actual control-system identity](https://www.postgresql.org/docs/18/functions-info.html), [session advisory locks](https://www.postgresql.org/docs/18/functions-admin.html), [table lock modes](https://www.postgresql.org/docs/18/sql-lock.html), [snapshot/locking ordering](https://www.postgresql.org/docs/18/applevel-consistency.html), and [database dump scope](https://www.postgresql.org/docs/18/app-pgdump.html). These support the design; they do not replace actual project-specific acceptance evidence.
