# QA / ProcessLogAuditor inventory

Sprint start: 2026-10-10 05:18:25 UTC / 10:18:25 Asia/Qyzylorda. Deadline: 13:18:25 UTC. Observer: qa_process, independent of app author root.

Initial inspection: project contained docs and README only. Diagnostic read returned exit1 because log paths did not yet exist; no app failure implied. Earlier sandbox/helper read failures were bypassed by authorized escalated reading, not proven repaired.

| Source | Status at initial inspection | Scope / limitation |
|---|---|---|
| qa_process tool output | captured | Own read results only; full project execution coverage not established |
| .local/logs setup/build/test stdout/stderr | missing | Root assigned producer; directory not present at initial inspection |
| flw/events.jsonl | missing | Root assigned producer; file not present at initial inspection |
| App/request logs | not-in-run | App not built/started at inspection |
| Mining jobs/cancel | not-in-run | Optional T08 not started |
| Migrations/cleanup/collector | not-in-run | No run observed; collector coverage remains to establish |
| GitHub CI/publication | missing | No raw outputs supplied to this observer |
| Agent events | missing | Only messages delivered to observer are visible |

Inventory must be updated as producers start; tail-only snapshots are truncated coverage. No global absence-of-errors verdict. Hash saved evidence; record intervals, volume, run/task/request ID, version and exit status. Raw sensitive logs stay private under ACL; public evidence uses safe aggregates.

Observation plan: poll new event/log availability while corpus work proceeds; correlate run IDs rather than infer causality from timestamps. Signal errors/repeats/hangs immediately. Before an expensive run require root's event with expected purpose and source paths. STOP_ProcessAuditor applies to evidenced critical deviation in affected scope, not missing app functions alone.

Acceptance: commit SHA + fixture SHA + independent expected result + actual verifier output for each AC. App checks currently unverified. Corpus files are prepared inputs, not test PASS.

Update after corpus preparation: flw/events.jsonl captured one sprint_started event; setup log observed while growing (snapshot coverage only). PA-SETUP-01: warning about missing MSVC prerequisites followed by GNU stable channel downloads; root notified to verify actual target/linker and executable launch. No STOP justified by this warning alone. tests/generate-boundaries.ps1 executed successfully to .local/qa-generated (large synthetic files kept out of public source corpus); this establishes inputs only, not admission-test success. Generated hash console output was visually abbreviated, so it is not a full hash manifest.

Next snapshot: installation log reports GNU stable 1.99.0 installed and no automatic PATH change; root rust_install event exit0 and hello_build_run event passed are captured. Independent observer has not replayed hello build/run. cargo-fetch.log full current snapshot (6337 bytes) inspected; SHA256 081C17317F1F6DF9E08805C1638E0CF100AAA08F22DBBCB5D26124E882FAF04B. It contains index/lock/download messages, no observed error, but completion exit event was missing at inspection. Full snapshot is not a claim of complete future stream coverage.

tests/core_contract.rs prepared against root API; Cargo deliberately not run concurrently with root fetch/build. Its expected values are manual, integration outcomes unverified until actual execution. UI handed off by PM, browser verification pending actual server URL.

PA-BUILD-02: observed core-tests-03.log E0277 Serialize Arc<Analysis> in web export json at web.rs215; root immediately notified. This is not PASS; no STOP asserted because common mechanism with earlier linker failure not established. tests/http_contract.rs prepared as independent router tests; execution delegated to root to avoid Cargo contention. Browser remains not-in-run. Prior test/build failures now appear in events but complete individual stdout/stderr coverage has not been inspected.

Live HTTP observation 2026-10-10T05:35:38.6909893Z against PID40760 / localhost3000 is recorded in qa-live-http.json (9 scoped checks). Core exact summary counts, SSE threshold/export agreement, invalid-import preservation and cross-origin rejection observed. This does not lift in-process HTTP test STOP or prove browser behavior. app.stderr WARN import_rejected/malformed_xml at 05:35:38.655366Z is tied to observer's expected negative upload. app.stdout empty in snapshot; request-completed logging coverage missing at current configured level. Playwright packages available, expected Chromium executable absent; no installation attempted. Native live server version has not yet been fixed to published candidate SHA.

QA-BROWSER-01: two actual headless Chrome runs using existing executable and isolated context failed at native upload POST /logs. Response403 cross_origin, Host127.0.0.1:3000, sec-fetch-site same-origin, Origin:null. Evidence .local/qa-browser/report.json and failure.png; root notified immediately. Likely global Referrer-Policy:no-referrer causes opaque Origin on POST navigation; proposed same-origin policy instead of broadly allowing null Origin. AC06 blocked; threshold/selection/panzoom not reached. Local requests only and CSP header observed. Tests use own app, no user profile/account. In-process HTTP STOP remains independent.

P2 independent QA vote: FOR scoped RESUME actual tools/cargo.ps1 direct rust-lld + llvm-dlltool path, old crashing executables not repeated, no release acceptance. Full wrapper-contract-tests-06.log observed core8/http6 passed; SHA2563AABB2D53AAD0DAF408031E4F6FC9C3AAB54487859BABB8ACB6C7DD54519027A. Relevant assertions not weakened. Browser regression after app-07 restart closes QA-BROWSER-01 on active path and 13 scoped assertions passed; see qa-browser-summary.md. Previous report filename reused across runs; historical initial failure remains in messages/inventory and failure screenshot, not claimed retained as a separate immutable JSON.
