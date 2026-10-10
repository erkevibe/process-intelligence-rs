---
name: project-windows-gnu-toolchain
description: Diagnose and restore this project-local Windows x86_64 GNU Rust build when raw-dylib import libraries, native DLL architecture, or HTTP test startup fail. Use for this project toolchain, not general Rust or MSVC setup.
metadata:
  origin: FLW-SkillManager
  source_problem: ENV-OBS-02 / ENV-OBS-03 / pinned-host-DLL-selection
  verified: 2026-10-10 / pinned-setup-11 / pinned-contract-tests-11
---

# Когда применять

Apply to this repository on Windows x86_64 with its pinned GNU Rust toolchain. The verified scope is Rust 1.99.0 GNU and LLVM-MinGW 20261006 host binaries. Other versions require new probes.

# Что делать

- Inspect tools/setup-windows.ps1 and tools/cargo.ps1 before modifying the environment. Keep installation project-local and use checked upstream archive hashes. The maintained scripts own exact versions and paths; do not duplicate them here.
- Extract LLVM DLL dependencies using exact host-root archive entries. This archive also contains target runtime DLLs with identical basenames; suffix or first-basename matching can select ARM or i686. All five host executables/DLLs used here must have PE Machine 0x8664.
- Verify llvm-dlltool by generating a real import library from a minimal .def. An unsupported --version invocation is not a readiness check. Detect both nonzero exit and missing output.
- The verified wrapper uses explicit llvm-dlltool plus direct rust-lld, linker-flavor=ld.lld and link-self-contained=yes. The bundled GNU driver experiment with -fuse-ld=lld did not establish an actual linker change and retained malformed import descriptors.
- For startup access violation, statically inspect the actual test binary and imports before repeating it. This incident had a TlsGetValue thunk but no loader-visible TlsGetValue import, with fault address inside import name data. Core tests and a live health route passing did not prove the HTTP harness was sound.
- After changing the mechanism, confirm loader-visible TlsGetValue and TlsSetValue along with GetTimeZoneInformationForYear, then run the existing HTTP assertions through the normal wrapper on the pinned toolchain. Record code/toolchain versions, logs and exit status.

# Чего избегать

Do not rerun an unchanged crashing executable or weaken assertions to obtain PASS. A separate target directory, changed binary hash or successful minimal hello does not establish full dependency/test readiness. This local fix does not certify enterprise readiness or portability to other platforms. Follow existing FLW STOP/resume rules; this skill adds no new permission or automatic resume.

# Проверенное основание

Independent review: flw/evidence/debt.md. Local evidence: .local/logs/pinned-setup-11.log and pinned-contract-tests-11.log; core 8 and HTTP 6 assertions passed. Raw logs stay private and are not copied into this skill. TechnicalDebt performed brief review of this skill against the actual installer/wrapper and PE host architecture.
