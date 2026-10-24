# Sprint09 audit and permanent project deletion

Implementation contract; independent acceptance is recorded separately. The frozen Sprint09 plan and original R3-01/R3-02 definitions remain authoritative.

## Successful business audit

New events contain server UTC time, monotonically increasing sequence, actor/project/resource IDs, action, positive resource/project revision, policy version/rule/validated-parameters SHA256, and `committed` outcome. The event and its mutation use the same PostgreSQL transaction. A refused operation does not append a successful event. Login/logout and a complete security-event ledger are outside this successful-business ledger.

The first setup is included: `platform_initialized` uses `empty_workspace_initial_admin_v1` and binds the newly created actor, administrator flag, initial owned project and empty-workspace requirement. Account creation binds its automatically created default owned project in the same auth transaction. Passwords, password hashes and session tokens never enter business audit parameters or exports.

| Operation | Parameters bound by the server |
|---|---|
| Strict XES / CSV import | Changed log IDs, source SHA256, normalization order, initial filter/calendar state; CSV includes the validated mapping and delimiter |
| Confirmed XES preview | Changed log/source, server operation ID, selected preview policy and retained action count; detailed immutable import provenance remains with the log |
| Filter / calendar | Affected log IDs, source/order and validated resulting filter/calendar settings |
| Personal view | This actor's persisted current log and personal views; no other actor's views |
| Model creation / save | Affected model IDs, name, source log, revision and model SHA256 |
| Folder lifecycle / assignment | Complete lightweight resulting catalog organization and explicit resource IDs |
| Job transition | Affected job IDs or jobs completing the imported result; validated durable snapshots |
| Interrupted-job recovery | Server recovery rule and durable post-recovery jobs |
| Project creation / rename / archive / restore | Actor/owner, name digest or archive state, expected revision where applicable, and session-replacement policy |
| Project backup restore | New project ID, name digest, validated repository digest before destination-ID remapping/trust normalization, imported history counts and explicit unverified-history policy |
| Membership / account creation | Validated user IDs, requested nonowner role or administrator requirement, automatic default-project IDs |
| Permanent deletion | Exact target/confirmation, expected auth/project/repository revisions, resource/member counts and server deletion policy |

Only the digest is retained for these parameters. It binds the validated inputs but does not reconstruct overwritten inputs or authenticate a journal against a database administrator. No payload, original filename, password or session is copied into the journal. Unrelated resident cache contents do not enter another action's policy.

Old events keep their original shape without policy/outcome and are shown as unknown. They are never backfilled as successful business events. New policy fields, outcomes and revisions are validated, including known-user references in auth business events; unsupported structures refuse loading. An older application does not support the new persisted shape: downgrade is not an accepted operation.

Client project backups cannot authenticate their historical actor, time or claimed result. Restoration preserves all retained historical content, sequence, counts and order, clears trusted policy/outcome and marks every imported entry `origin: project_backup_unverified`. UI and export distinguish that history from ordinary legacy unknown records and this server's new committed mutations. Unknown origins and imported-origin entries carrying trusted policy/outcome refuse loading. The authentic server restore event remains atomic and binds the validated original repository digest and normalization policy. Full operator PostgreSQL recovery preserves stored entries exactly and does not perform client-import normalization. The additive trust-policy decision and required negative cases are recorded separately.

Project and auth-project trails retain the latest512 entries with explicit total/dropped counts and ordered export. Deleted-project witnesses have separate512-entry trails per former owner. Another owner's activity cannot evict this owner's witnesses. Export schema2 distinguishes current-project, auth-project and former-owner deletion projections; it does not expose other users' witness trails.

## Permanent project deletion

Before archiving their current project, the initiating owner must have another active project with write access. All affected sessions of that owner prefer a writable replacement; only Viewer alternatives cause refusal before data or audit changes. Other affected users may select their own accessible Viewer project. This prerequisite does not extend to archiving a noncurrent project. The additive Council decision is recorded separately from the unchanged frozen plan.

`GET /projects/{id}/delete` returns a preview for an already archived target, bound to the current actor/session, membership, auth revision, project revision, repository revision and impact counts. `POST` requires that exact project ID, the phrase `УДАЛИТЬ`, revision and preview digest. Unknown form fields, changed access, stale previews and nonterminal durable jobs refuse deletion. All project mutations recheck current write access under the auth lock.

Auth is locked before reading the durable project header. A single storage command checks and locks auth and repository CAS versions, saves updated auth/session references, removes every target normalized record and header, removes the target migration marker and exact `repository/{id}` legacy key, and commits once. It changes no other project or resource sequence. Target sessions select only their own accessible active replacement project or terminate.

Only after acknowledged commit does the application publish the new auth state and evict target workspaces, pending CSV/XES previews and cached resources. A previously captured actor or worker rechecks current auth before publication and cannot write the deleted project back. Unknown commit acknowledgement leaves the worker unavailable and does not publish a guessed success; inspect/restart rather than blindly repeat the operation.

The deleted header and its old project journal disappear. Each former owner retains a minimal witness: IDs, action, time, revision, server policy/digest and committed result. It contains no project name, filenames or payload. Project IDs are generated freshly by the server; callers cannot supply or restore an old target ID. Generation checks current and retained deleted IDs; bounded retention is not an eternal tombstone registry.

## Recovery and operator expectations

Deletion has no automatic undo. The interface asks the owner to save a full backup and verify recovery into a new database; the application does not claim it has verified an operator's backup. Sprint acceptance separately requires an actual complete stock backup/new restore on independent owned fixtures.

Backups and older PostgreSQL versions of rows can retain deleted content. Logical deletion does not promise physical secure erasure or immediate file shrink. Offline retained-legacy cleanup is a separate operator operation described in `SPRINT_09_CLEANUP.md`; it preserves current normalized/auth data and is not project deletion.
