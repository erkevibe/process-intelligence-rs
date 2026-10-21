---
name: project-windows-postgres-package
description: Diagnose this project's portable Windows PostgreSQL package bootstrap, private-directory ACL, pg_ctl process waiting and Windows PowerShell 5 launcher encoding failures. Use for this repository's bundled local PostgreSQL delivery.
metadata:
  origin: FLW-SkillManager
  verified_scope: PostgreSQL18.6 / Windows local package bootstrap / package07
---

# Scope and evidence

Use for this repository's portable Windows PostgreSQL18.6 package. Maintained setup-postgres.ps1/start-packaged.ps1 own versions and paths. Read them before changing a mechanism. This skill does not certify release acceptance, general PostgreSQL administration or interrupted initialization recovery.

Real package07 evidence verified 1635 manifest file hashes/sizes, fresh bundled first initialization, app-role nonsuperuser transaction probe, and Windows PowerShell5 role-exists/database-missing recovery. Evidence belongs to source acb3cf024aecc8bcb2641854875654511288c34c, not automatically a subsequent source. Public audit: flw/evidence/sprint-02-debt.md. Raw logs remain private: .local/logs/s2-package-bootstrap-07.log, s2-package-bootstrap-recovery-07.log and s2-package-verify07.log.

# Tested bootstrap mechanisms

- Establish a private project-local data directory before writing passwords or SQL. Fresh Set-Acl descriptor application failed with SeSecurityPrivilege on a non-admin package run. The maintained repair persists the modified access section via DirectoryInfo.SetAccessControl on Windows PowerShell5 or FileSystemAclExtensions.SetAccessControl when the instance method is unavailable. Verify protected inheritance, exactly one non-inherited Allow FullControl rule and current-user SID after applying it. Do not request administrator execution to conceal a DACL-only repair or skip the postcondition.
- Start pg_ctl with hidden Start-Process, redirect output to private logs and wait for pg_ctl itself with a bound. A long-lived postgres child inheriting caller pipes previously kept the shell bootstrap alive despite a healthy server. A healthy existing server alone does not prove first initialization worked.
- Independently check role and database existence. A role present with its database missing must create the missing empty database on rerun; keeping CREATE DATABASE only inside CREATE ROLE's branch leaves a failed bootstrap unrecoverable. Never drop existing user databases for a readiness probe.
- Select an available loopback port and inspect ownership of any collision before action. package06 startup failure was followed by package07 on a free port; rerunning unchanged port collision is not a mechanism repair. Stop only a process positively identified as owned by the current test.
- Confirm actual current_user app role, rolsuper=false and transaction behavior, not merely postgres --version. Never print private config, PGPASSWORD, database URL or credential SQL.

# Windows PowerShell launcher encoding

Windows PowerShell5 native launch failed parsing an em dash in a UTF-8-without-BOM launcher. Keep cross-shell launcher messages ASCII or explicitly use an encoding validated by both Windows PowerShell5 and PowerShell7. c0180a2bf0069b599f112226a10a13f67ce82f17 applies the ASCII repair; actual native Windows PowerShell5 Start.ps1 launch on that candidate subsequently succeeded with a stock Windows PowerShell module environment, health0.2.0 and real setup/login requests (s2-packaged-app-state.json and s2-packaged-app01.stdout.log). Full browser/restart acceptance remains separate. Do not convert parser PASS into application startup PASS. Retained failure: .local/logs/s2-packaged-app01.stderr.log.

Inherited Codex PowerShell7 PSModulePath contaminated a spawned Windows PowerShell5 child and Get-FileHash was unavailable. The test harness restored only the child's stock Windows PowerShell5 module path, preserving the parent and global environment. This establishes normal native-shell launch, not arbitrary inherited custom module-environment portability. Inspect module resolution before changing product code or installing modules; broader cross-shell support may require an explicit compatible PSHOME module import.

# Limits and completion

Fresh extraction must contain no private data or credentials and every manifest byte/hash must match before startup. Verify source/build proof independently, then perform actual setup and native launcher/browser checks on the exact new candidate. The author of build/package scripts cannot independently accept those scripts. Existing initdb-before-private-config interruption window remains documented operations debt; this skill does not claim all crash-recovery windows are handled. Follow project FLW STOP/resume rules without adding new automatic permission or resume.

## Newly observed cold native PS5 gate

Earlier native launch used an already-running PostgreSQL server. Subsequent cold user installation failed despite server readiness because PassThru ExitCode was null. Actual s2-ps5-exitcode-probe.log establishes that acquiring Process.Handle before WaitForExit returns the real exit7; Refresh alone does not. Maintained repair reads the handle immediately after Start-Process and preserves timeout/nonzero rejection. This repair still requires actual native PS5 cold-first-init and exact new package evidence; earlier package08 acceptance is superseded. Do not claim cold-path coverage from a warm existing server.

Cold repair10 is now actually verified: native Windows PowerShell5 fresh PostgreSQL initialization on5546, role/database creation, transaction rollback, nonsuperuser and exit0 (s2-native-ps5-cold-repair10.log/json). Source d0784e2766f5af875225e62f85aa11f85ccce5d9 adds only Handle retention/comments. This closes mechanism proof, while the exact new package's public Start/browser/restart and council approval remain required. A verifier launching native PS5 through inherited pipes can itself wait for PostgreSQL descendants; wait only the owned PS5 process with its handle, and report actual app/PG readiness separately.

Exact package11 on d0784e2766f5af875225e62f85aa11f85ccce5d9 now passed actual cold native Windows PowerShell5 public Start on separate fresh PostgreSQL5544 and5435 clusters. Independent QA package manifest1635, DACL/nonadmin, browser/roles/UI and public restart evidence closes COLD01/A12 for this candidate only (sprint-02-qa-d0784e.md, sprint-02-qa-package11.json). Separate user installation presents first-account setup without QA users. Historical c018 vote remains superseded; exact S2-R2 council rawhash FAB3BF5228599D0C22F4024912258F61626CF9D5416A0F93349435F1B1F86C98 identifies the new resolution.

## Sprint04 interpreter scope and frozen operator instructions

For C1 source f3a3ad4, native Windows PowerShell5.1 cold Start and selected restored-database Start/browser were verified. The complete stock backup/new restore/offline migration path was verified under PowerShell7.6.5, including full values/versions and corrupt/existing-target/active-app refusals. Do not transfer those results to native5.1 backup or arbitrary7.x versions. See the fixed independent sprint-04-qa-final-report.md and sprint-04-td-final-report.md in flw/evidence.

Expose this tested prerequisite before recovery and follow a pinned current operator guide with consistent installation, restored Database and PostgreSQL port. Reviewed ZIP instructions remain a source-freeze snapshot: disclose outdated5.1 backup examples in release notes and direct operators to the corrected guide. Do not edit manifest-protected files or silently repackage reviewed bytes to retrofit documentation.

Repeated native5.1 backup attempts produced suspended, zero-CPU children and empty logs without archive execution proof; a separate private composed verifier was blocked by security software. Equivalent retries stopped. Preserve UNVERIFIED scope, identify exact owned resources before cleanup, and investigate a different evidence-backed mechanism before an independently observed cold full-chain retry. The cause/vendor was not established; this is neither a solved blocker nor a demonstrated product incompatibility. Do not disable protections or resume suspended threads to manufacture a passing result.

Append reviewed by Root against actual independent QA/TD evidence; no runtime or global skill installation change. Final Council/public delivery acceptance remains separate.
## Bounded native identity and JSON date guards

For this project's Windows package/build/recovery observers, normalize both executable paths with `Path.GetFullPath` and compare ordinal-ignore-case. Forward/backslashes alone caused a real identity guard refusal; do not bypass path checks or substitute basename-only ownership.

Preserve JSON creation timestamps as literal strings (`ConvertFrom-Json -DateKind String` on the tested PowerShell7), parse ISO offsets explicitly with `DateTimeOffset`, and compare UTC ticks to CIM `CreationDate.ToUniversalTime().Ticks`. Do not compare display formatting, auto-converted JSON dates, or unspecified/local DateTime ticks. Missing/ambiguous identity must refuse before any process mutation; a refused guard is not a successful kill/recovery test. The separately suspected migration-guard representation failure remains unverified until its actual isolated replay.

Root observations in current PID + creation + normalized executable path. Build ancestry from each observed live snapshot with present parents and child creation not earlier than its current parent. Keep captured identities as PID+creation; never reuse a historical PID set as an ancestry seed. Actual Sprint08 stale PID reuse incorrectly captured unrelated QA children; the repaired observer and fresh03 passed independent targeted Council review. See sprint-08-td-pid-closure-position.md and sprint-08-qa-observer-closure01.json under flw/evidence.

CIM polling is non-atomic sampling: missing paths, short-lived/exited-parent children and uncaptured child exits remain unavailable. Capture actual main native handle/exit and full streams separately. This does not authorize terminating processes or promise kernel/full-machine ancestry. Preserve contaminated/failed attempts; freeze fresh evidence for changed mechanisms rather than relabel them.


## Bounded browser file selection on a live fixture

For actual browser file upload, inspect the current visible DOM file input and use only currently documented computer-use APIs. Start the chooser wait and the observed input activation concurrently, with finite per-action/tool bounds shorter than remaining fixture lifetime. A timed-out chooser is a diagnostic failure: check fixture liveness and resolve the pending interaction before another upload; do not queue follow-up API/UI work after the fixture deadline. Preserve the failed attempt and distinguish tool success, page response and server-side saved bytes. Actual browser permission denials remain binding; never switch channels to bypass them. This mechanism was used for successful S16 pre-restart uploads; it does not establish completed reimport/restart or arbitrary file-picker portability.


## Pin transitive sibling runtime dependencies

When reusing a wrapper/worker, resolve each relative import from the exact copied file PSScriptRoot and verify the reachable sibling runtime modules, scope/bounds and executable hashes. Byte-identical outer code at a new path can execute a different dependency. A new sprint changes only the explicitly reviewed diagnostic paths/deadline/ports/nonce; retain real package bytes. Review the narrow resolved-path/hash diff before launch and keep the earlier failure unchanged. Do not weaken private ACL, path/reparse, native ownership, output limits or free-space guards merely to make relocation run. Full old-tree inventory is unnecessary for a small isolated wrapper relocation when protected trees remain read-only.


## Distinguish global site permission from conversation denial

For this project local browser checks, a global site allow and developer mode do not establish that the current conversation is allowed. If the normal tool returns persisted_user_denied, inspect only the relevant permission metadata and compare global versus current-conversation settings; preserve the refusal and stop blocked-origin retries. In the observed0.7.4 completion, an older conversation-specific origins deny survived global allow and desktop restarts. The user revoked that exact denial themselves, after which the normal Browser Use tool reached the existing server. Do not erase the permission file, change policy/bridge code, reset unrelated permissions or switch browser/API/host/port to bypass the refusal. Confirm actual current tool access after the user change; successful server startup, manual user navigation and full CDP are separate observations. Protect identifiers/raw diagnostics privately, and do not claim an untested cache or product fault.
