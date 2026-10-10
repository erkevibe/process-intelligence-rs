# Candidate QA pending clean replay

Candidate source: d942f13306eabc0c3c9776f3bcbab26042384279, branch codex/sprint01, draft PR1. This report is independent qa_process assessment; no app source authored by observer.

Prior live HTTP/browser/admission evidence is draft evidence, not asserted as validation of this SHA. Clean checkout setup/build/replay is pending. Published SHA fixes source identity, not acceptance. New clean browser/API outcomes will be added only after actual replay against root-confirmed clean port3001.

Latest independently read pinned-contract-tests-11.log reports core8/HTTP6 passed; pinned-clippy-12.log finishes without diagnostics. Their content proves recorded runs, but no automatic mapping to candidate SHA without clean checkout replay. clippy-07.log failed due to incorrect argument forwarding; later pinned clippy records successful replacement path. clean-setup.log reports pinned GNU1.99.0 install, components and cargo; actual clean application build/launch pending.

Coverage snapshots and hashes: qa-coverage-candidate.json. captured means full available snapshot inspected, not every historical event observed. Unreviewed existing logs marked missing for independent content coverage; tail-only core03 marked truncated. Source files changing later invalidate snapshot completeness. app07 warning events match known deliberate malformed/event/case/activity rejection scenarios; unrelated timestamps do not independently establish causality.

Events include historical startup/failures and later baseline_candidate_published; no continuous complete chronology claimed. Retrospective consolidated task cards must be labelled retrospective, not represented as prewritten or simultaneous monitoring. Git push and GitHub Actions raw logs/status not provided to this observer; missing. No release/product PASS or clean AC01 claimed yet.

Hash snapshot limitations: active app07 stdout/stderr and clean-build.log were sharing-locked; their SHA fields are null. Hash failure does not mean sources were empty or error-free. New draft live risk QA-LIMIT-22M:22MiB upload ended in transport connection reset, no HTTP status observed, prior export retained. qa-largebody.json records failed scoped check; +1byte admission PASS does not cover total multipart body-cap path. Root notified. Candidate clean replay must include this distinct negative scenario once fixed.

## Actual clean browser replay

Observer independently read .local/clean-baseline git HEAD=d942f13306eabc0c3c9776f3bcbab26042384279 and empty git status. Root setup/build and port3001 readiness supplied; clean-build tail independently inspected (tail coverage only). Isolated existing Chrome against clean server3001 replayed fourteen assertions successfully: previous thirteen browser checks plus22MiB client guard shows clear20MiB message, sends zero upload requests, preserves full graph state. Detailed headers/HTML remain private in .local/qa-browser-clean-d942f13-with-guard/report.json. These scoped observations now belong to this source SHA; all previous draft evidence remains separately labelled.

Distinct server cap issue persists in baseline: changed-mechanism curl Expect100continue observation on draft3000 returned actual400 after100Continue for22MiB; prior DotNet writer yielded transport reset. New independent HTTP oneshot regression requires413 and preserved export; timestamp-error regression requires user-visible1-based source location. These new tests are outside frozen candidate and pending root run on corrected code. Client guard PASS does not close server cap failure; overall baseline acceptance remains partial pending patched candidate.

Subsequent patched draft regression closed active-path cap/context findings: contract-tests14 core8HTTP8 passed; curl final413 with0upload bytes and retained export; actual browser14 scoped checks passed. See qa-patch14-summary.md. These results are not attributed to baseline d942f13 source. Clean baseline browser report SHA339F64CF3687C8C84F2476FC8B18E455772A082B85D38A43F8CB6FE41217D9F0.
