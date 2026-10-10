# Sprint02 independent pre-freeze result

Owner QA/ProcessLogAuditor, independent app author. **Pre-freeze checks passed; final acceptance pending frozen SHA and clean replay.** Version0.2.0 debug build04 used for this run; root reports subsequent human calendar-table UI changes not present in this executable. No complete original R2–R5 or Apromore compatibility claim.

| Executed source | Actual result |
|---|---|
| Root integrated-tests04 completed file | 49 normal tests PASS; two real-PG tests explicitly ignored in ordinary run, not credited there |
| Independent explicit isolated-PG run `.local/logs/s2-qa-platform-pre02.log` | 2PASS: CAS/write_batch rollback, fresh connection, HTTPauth/RBAC/log persistence/invalid restore, hash-valid threshold0 rejection, concurrent AppState sameDB lease reject, oldrouter drop/reopen, logout API denial |
| Own jobs live `.local/qa-sprint02-pre-jobs/report.json` | 6PASS: actual running/queued states before abrupt owned process termination, interrupted/null recovery, no additional logs, activejobs backup_busy422, accepted cancellation terminalnull/idempotent, actual PostgreSQL stored completed result links exist, foreignuser job snapshot/events/cancel denial |
| Native browser `.local/qa-sprint02-pre-browser/report-before.json` | 20PASS: mapped CSV/timestamp-order, visible pickerB removal, exact counts, calendar3600000/0, actual canvas click→Apply→nativeSave, modelrevision/labels/xy/XMLcontents, rawbackup restore freshproject log/sourcehash/params/model equality, wrongversion reject/original unchanged, foreignuser known log/model exports denied, zeroJS exceptions |
| Separate actual sessions `roles-report.json` | 5PASS: viewer read/export/backup, forged write denial across11resource paths, editor model-save/revision, stale409, actor threshold isolation |
| `csv-negative-report.json` | 2PASS: physical row2 error and complete previous committed export unchanged |
| `model-limit-report.json` | 2PASS:245tasks/4096bytelabels inputwithin1MiB but canonical aggregate overflow rejected before publication, existing model/inventory unchanged |
| `capacity-report.json` | 2PASS: persistent new project accepts8 logs/rejects9th and preserves all8full exports |
| `restore-collision-report.json` | 2PASS: ownQA allocator set to occupied restored logID, newimport skipscollision; prior model/log contents preserved |
| Actual owned process44488→24496 `report-after.json` | 4PASS: full export, shared editor-saved model revision/labels/positions and live diagram model preserved |
| `lease-report.json` | 3PASS: exactlyone ownQA advisory backend terminated; health/protectedexport/projects503 failclosed, no cachedsource data |

Only database `pi_qa_sprint02` reset and used, credentials privately loaded without printing. Root/R1 apps and PostgreSQL server untouched. Own job child handles closed; QA process24496 stopped with exact executable path check after lease test; QA port3011 free. Lowsequence exercise only own isolatedQA DB. No global PG/service/user process shutdown.

## Observation and failures retained

Stopped own app pre01/pre02 fully automated JSON-line parsing:386/42lines,0unparsed; stderr0bytes. Safe hashes/status counts in `sprint-02-qa-pre-log-summary.json`. AUD2-01 visibility closure observed: all11viewer403 now logged, all3lease503 now logged. One WARN `import_rejected code=log_limit` is expected ninth-log negative test. Full stopped-file coverage is **not** all shell/lifetime/agent coverage. New candidate/CI/package sources still pending; early distribution download complete raw transcript remains missing/attributed.

Root clippy07 completed file PASS; root integrated-tests04 read result lines and complete automated file scan, not proof later source unchanged. Earlier ignoredPG count explicitly replaced with real isolated execution, not inferred PASS.

Initial QA wrapper invocation lost argument separator under PowerShell; preserved pre01 log, changed mechanism to explicit CargoArgs array and pre02 actual2PASS. Initial picker browser matched main plus new reset forms and clicked reset; retained failure (`report-picker-initial-reset-selected.json`), corrected selector to main `.platform-form`, actual20PASS. Other earlier verifier issues in observation report remain retained. No product assertion weakened; no production file changed by QA.

Current judgment: no reviewed blocking product failure in this pre-freeze run. Scope mandatory A01–12 appears independently exercised at selected-slice level, but **no final accepted verdict and no final council vote yet**. Clean frozen source setup/build/checks plus exact-executable replay and final limitations remain necessary. Full original-stage criteria, arbitrary BPMN, DST/IANA calendars, SSO/distributed jobs and legacy compatibility remain outside/unverified.
