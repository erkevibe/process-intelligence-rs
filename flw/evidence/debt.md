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
