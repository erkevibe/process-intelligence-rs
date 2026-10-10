# Независимый TechnicalDebt / SkillManager — Sprint 01

## Environment advisory

Read-only inspection: rustc, cargo, gcc, clang, cl, link and ld were not found by Get-Command. Standard user Cargo bin, MSYS2/MinGW, LLVM, VS Installer, VS directory and Windows Kits Lib paths were not found. This proves only the inspected paths, not absence everywhere on the machine.

Recommendation to root: isolated stable-x86_64-pc-windows-gnu, project-local RUSTUP_HOME/CARGO_HOME, explicit executable paths. Verify the installed sysroot linker through a minimal real compile and run before choosing this path. No toolchain was installed by this auditor. MSVC requires a compatible linker and SDK; downloading rustc alone does not provide this proof.

## Findings

ENV-OBS-01: toolchain readiness unverified. Category: environment prerequisite, not application debt. Owner: root/Operations. Impact: first milestone at risk. Closure: exact toolchain version, successful minimal build and actual local execution recorded. Status: open. Due: T01.

SOURCE-OBS-01: src and tools absent at the time of the first inspection. Category: not-in-run, expected before implementation. No product defect or STOP asserted.

## Debt scope

No current application debt established. Future auth, persistence, permissions and BPMN are missing roadmap functionality, not debt without an active path and proven harm. Enterprise readiness must not be claimed for the local R1 without separate acceptance of those boundaries.

## SkillManager

No verified environment solution yet; no project skill created. Retain successful resolution evidence before considering a skill. No application tests were executed by this auditor.

## ENV-OBS-02: repeated Windows GNU import-library failure

Evidence: .local/logs/core-tests-02.log reports dlltool CreateProcess while compiling getrandom and windows-sys raw-dylib imports. tools/cargo.ps1 explicitly adds rustlib bin/self-contained to PATH. Read-only inventory confirms dlltool.exe and x86_64-w64-mingw32-gcc.exe exist there; as.exe does not. The first failure, dlltool not found, was reported by root; this auditor directly inspected the second log. Missing assembler is a supported causal hypothesis, not a proved result until a targeted probe.

Impact: dependency build and trustworthy application checks are blocked on this toolchain path. Owner: root/Operations. Priority: high environment blocker. Status: open. Do not repeat an equivalent full Cargo build before changing and probing the common import-library mechanism. Safe UI, fixtures and documents may continue.

Recommended repair experiment: upstream portable LLVM-MinGW Windows x86_64 archive under .local; retain GCC linker and configure rustc -C dlltool=<absolute llvm-dlltool path>. Official rustc codegen documentation supports the explicit dlltool option: https://doc.rust-lang.org/rustc/codegen-options/index.html . Portable archives documented by their upstream: https://github.com/mstorsjo/llvm-mingw . llvm-tools-preview membership of llvm-dlltool was not confirmed, so component installation solely on that assumption is not recommended.

Closure: record archive provenance/version/hash; demonstrate import-library creation from a minimal .def; demonstrate raw-dylib rustc probe via the same dlltool setting; then rerun relevant application Cargo checks through the actual wrapper with full exit status/log. Independent QA and TechnicalDebt review required before accepting recovery. No repair, probe or PASS was performed by this auditor.

## ENV-OBS-03 / STOP_DEBT: HTTP test harness native startup crash

Direct evidence: .local/logs/contract-tests-05.log shows core_contract 8 passed and http_contract-e5b7411b082aa37c.exe exit 0xc0000005 before any HTTP test result. Windows Application Event 1000 independently records this same executable at host event times 10:31:47 and 10:32:10 on 2026-10-10, both exception c0000005, module unknown, offset 00000000010efc44. Times are event host times, not an inferred timeline across clocks. The separately named http-list-probe log was not found; event evidence independently confirms repeat signature.

STOP_DEBT scope: do not rerun unchanged HTTP test binary; do not mark HTTP acceptance passed or accept release on this path. This is a high verification blocker, not evidence all application routes are broken. Safe fixtures/UI/docs and observational live API checks may continue. Owner: root/Operations. Status: open.

Causal status: old GNU linker versus LLVM import library interaction is only a hypothesis. Fault module unknown and common instruction offset do not prove linker causality. Recommended controlled experiment: bundled ld.lld.exe through existing GNU driver with explicit -B search directory and -fuse-ld=lld in a separate target-dir, preserving current dlltool and CRT; direct rust-lld GNU mode is another hypothesis requiring correct startup/search paths. The existing portable archive contains llvm-readobj, llvm-objdump and llvm-nm for inspection; no extraction or binary execution performed by this auditor.

Resume/closure: change and document actual startup mechanism; minimal libtest/Tokio listing probe passes; modified HTTP harness --list and all assertions pass; verify actual wrapper path and relevant regression; independent QA and TechnicalDebt conclusions; ProcessLogAuditor findings considered; explicit council resume. Root must not weaken assertions or substitute source presence for test evidence. No new application PASS declared here.

## ENV-OBS-03 forensic update: import descriptor omission

Read-only PE analysis found original HTTP crash RVA 0x10efc44 inside .idata, not .text. Bytes at that RVA are the hint/name record for TlsGetValue. llvm-nm resolves TlsGetValue thunk at VA 0x140d35134 and __imp_TlsGetValue at VA 0x1410eede0. llvm-objdump shows the thunk jumps indirectly through that IAT slot.

llvm-readobj --coff-imports on HTTP harness lists a lowercase kernel32.dll descriptor containing only GetTimeZoneInformationForYear; it does NOT list TlsGetValue/TlsSetValue and other windows-sys kernel32 APIs despite their linked thunks. In contrast, the working application PE descriptor lists 21 kernel32 APIs, including TlsGetValue and TlsSetValue. This localizes a concrete import table inconsistency explaining a jump into unresolved import name data. Suspected origin: combination of separate raw-dylib kernel32 import libraries (chrono versus windows-sys). Exact producer and repair remain to be verified; this is not proven Rust source logic failure or stack exhaustion.

Original and purported LLD HTTP images have identical key PE layout (entry RVA 0x13f0, .idata RVA 0x10ee000, TLS RVA 0xf3c400). SHA256 differ: original DC0352660C482EFA729346A43498A6CDC9E53D674BC08B2C93F3CDE17AF71317; target-lld FDB094BE163D9C55BEFB924987E44B0BE565BB1273BF0CF202A65C9EC5A05262. A different target directory or different SHA does not prove actual linker replacement; require verbose linker identity or -v evidence.

No crash executable was run by this auditor. STOP remains open. Repair must produce loader-visible TlsGetValue and TlsSetValue imports, followed by real harness execution and existing assertions without weakening them.

## P2 independent recovery review and TechnicalDebt vote

Vote: FOR exact P2 supplied by root: allow tests/build on corrected direct rust-lld + llvm-dlltool path, ENV-OBS-03 scope; old crashing binaries remain outside the path; this is NOT release acceptance. Full council decision and independent QA/ProcessLogAuditor conclusions still govern actual resume.

Read actual wrapper-contract-tests-06.log: completed standard wrapper compilation followed by core_contract 8 passed and HTTP contract 6 passed. Exact HTTP executable from log: target/debug/deps/http_contract-c7cceea2b7937f67.exe. Independently inspected this PE with llvm-readobj: MajorLinkerVersion 14, Minor 0; imports GetTimeZoneInformationForYear, TlsGetValue and TlsSetValue are all loader-visible. Binary SHA256 04F38CD59987EAB0538E572BCA7B6E777534F770DA9E2213D96B3B088D166299. Log SHA256 3AABB2D53AAD0DAF408031E4F6FC9C3AAB54487859BABB8ACB6C7DD54519027A.

Reviewed wrapper SHA256 6B5369FAD7061C1DD79CFCAA0E208566D917DE9C51C8175408A796D49839F819. It explicitly selects direct rust-lld, linker-flavor=ld.lld, link-self-contained=yes and llvm-dlltool. New pinned-GNU selection falls back to the existing stable GNU toolchain because pinned 1.99.0 GNU was not present during this inspection. This fallback is acceptable only for P2 recovery scope; installing/selecting exact GNU pin and retesting remains a pre-delivery reproducibility task. No release-ready verdict here.

Mechanism closure supported: previously missing loader-visible TLS imports are present on the actual wrapper test binary, and the original HTTP assertions execute successfully. Stop finding may move to recovered-for-tests/build upon explicit council resume, not closed-for-release solely by this vote. Reappearance of the import inconsistency reopens ENV-OBS-03.

## Pinned environment recovery / SkillManager capture

Read pinned-setup-11.log and pinned-contract-tests-11.log: exact GNU Rust 1.99.0 setup readiness, core 8 and HTTP 6 assertions pass. Actual pinned HTTP PE includes TLS and GetTimeZoneInformationForYear imports with linker major 14. Independently inspected PE Machine of llvm-dlltool.exe, libc++.dll, libLLVM-23.dll, libunwind.dll and libwinpthread-1.dll: all 0x8664 (x86_64). tools/setup-windows.ps1 uses exact host-root GetEntry, replacing ambiguous suffix lookup in the multi-target archive, and uses a meaningful real.def -> import.lib probe. The earlier pin failure is a historical environment incident, not persistent product debt after this evidence.

Environment recovery supported for current pinned setup and wrapper. Clean-release and product acceptance remain pending; no enterprise-ready or application release PASS inferred. Setup SHA256 DA4283CBFFD322AF923C1F2F6648F611795994AE222D72945D90DABBB6272A36; wrapper SHA256 6B5369FAD7061C1DD79CFCAA0E208566D917DE9C51C8175408A796D49839F819.

SkillManager: created flw/skills/project-windows-gnu-toolchain/SKILL.md after repeated/high-cost failures and verified recovery. No duplicate project SKILL was found outside ignored build/local trees. TechnicalDebt brief reviewed narrow scope, real evidence and absence of permission expansion. Official skill-creator quick_validate was attempted but failed to import yaml (PyYAML absent in bundled Python). Manual format review completed; official validator PASS is NOT claimed. This tooling limitation does not undo the independently demonstrated Rust build recovery and does not block product development. Skill is project-local knowledge, not globally promoted or automatically installed.

## T08 source review before candidate

Reviewed src/jobs.rs, src/web.rs worker/upload/SSE paths, static/app.js graph guard, and .local/logs/t08-tests-16.log. The log reports 7 jobs contract checks passed; this auditor did not execute them. This is source review, not final browser or product acceptance.

Cancellation publication: cancel and complete_with share the snapshot mutex; accepted cancellation suppresses commit. Terminal snapshots are immutable. Two job leases and one shared CPU permit bound accepted workers; job lease remains held through actual processing and publication. No current lock cycle found in inspected job/entries/repository calls. Raw Rust4PM parse noninterruptibility is disclosed.

T08-TD-01: source-supported stale HTML risk, owner root/web, priority high for AC07/AC14 composition, status open before candidate. src/web.rs job_events (lines 537-548 at review) patches analysis-panel for any completed result_id still in repository. Reconnecting an older completed job after a newer import can emit old analysis HTML. static/app.js rejects stale graph JSON by analysis/version but does not undo already morphed old stats/forms/case details, allowing mixed-version UI. Closure: old completed result cannot replace newer active analysis; deterministic HTTP/browser test reconnect old completed job after newer log plus delayed old completion/view interaction. Source finding is not a performed browser reproduction, and no STOP asserted yet.

T08-TD-02: admission slots do not bound concurrent upload buffer memory. upload_to reads up to 20MiB per request before enqueue_job creates a lease or synchronous import acquires CPU (web.rs 220-270). Accepted workers are bounded, concurrent receive buffers are not. Impact: local repeated concurrent uploads can exceed intended bounded-memory interpretation. Priority moderate for local R1; owner root/Operations. Proposed due: before network/shared-user operation in R3; enforce concurrency admission before reading upload or global aggregate receive budget, retaining per-file size checks. Do not describe max2 jobs as total request memory cap. Source risk, no resource-exhaustion measurement performed.

## T08 findings recovery review (tests18)

Directly read .local/logs/t08-tests18.log: core 8, HTTP 8, jobs 7 and optional HTTP 7 assertions passed (30 total). Reviewed actual regression sources in tests/optional_http_contract.rs, not just count. Tests were run by root; this auditor reviewed evidence.

T08-TD-02 CLOSED for inspected upload-buffer admission scope. Current upload_to acquires a two-slot uploads semaphore before multipart.next_field/chunk reads. Notify-controlled test holds two real incoming body streams, demonstrates third request 429 and health 200, then releases streams. This removes the identified unlimited concurrent receive buffers. It does not establish a global RSS bound: accepted job input, parse expansion and retained logs require separate AC11 measurement.

T08-TD-01 SERVER FIX VERIFIED, browser composition pending. Current job_events emits analysis-panel only when completed result_id equals repository.current under the repository lock. Regression old_completed_job_reconnect_does_not_replace_new_current_analysis passes and explicitly asserts no analysis-panel SSE from an old completed job after newer import. static/app.js now clones the whole last accepted analysis-panel and restores it for stale versions or wrong log/version identity. This addresses stale HTML already in flight; independent browser test must verify restored Datastar interactions, form target, case details, graph/panel versions and pan/zoom on the updated server before full closure.

No new blocking lock/cancellation defect found in inspected scope. Root reported clippy/build18 passed; not independently read in this update. Single locked-app-binary build incident is not automatically a two-failure shared mechanism. Future auth/persistence remain roadmap functionality, not current debt.

## T08-TD-01 closure after independent browser evidence review

CLOSED for inspected T08 integration. Read .local/qa-browser-stale18/report.json: 5/5 scoped checks passed, including exact same-log full-panel restoration with identical graph pan/zoom/revision, subsequent real Datastar rebind action, previous-log rejection, subsequent case binding and no JS exceptions. Read optional18/report.json: 10/10 scoped checks passed, including actual job accepted/streamed/completed, terminal reconnect, visible failure, actual accepted cancellation ending cancelled/result_id null and case/threshold highlights with stable pan/zoom. Combined with tests18 old completed reconnect regression and current-result server guard, identified cause and consequences are addressed. This is scoped independent evidence review, not an auditor-executed browser run.

Source hashes at closure: src/web.rs EE6A7229A4B67F546D443441AEFC0CDA36039EDF468D08217EA316B40EB935BD; src/jobs.rs 873E52DD4B0393700B25633368F570950DACF8EE00AC65413E13E769BCF7F61D; static/app.js DB054168DF92E208FD07A24B660E3098D1A3CCB6FE92DB044CBF27335EDB251F. Evidence SHA256 stale18 40F7DD393BE3C5411E17F178BCFFA5F2A3E245EC4000846295384CF00285654D; optional18 A17B5E861AA6BC3C5110AA4D0AABFC90005828D7394B29476077FFCBBFCD14DC.

Publication/source scope review: vendor hashes independently match manifest; licenses retained separately and Cargo dependency license fields recorded. No missing license field or mandatory GPL-only field found by this limited manifest scan; dual-license alternatives are not treated as mandatory LGPL. This is not legal certification or transitive license text audit. .gitignore excludes .local, build dirs, node_modules and raw logs. Project-local skill has brief review and recorded missing PyYAML validator limitation. R1 claims remain local/in-memory; enterprise readiness and legacy equivalence are excluded. Final candidate SHA and clean release evidence still pending; no final release acceptance asserted.
