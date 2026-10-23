---
name: project-capacity-budget-sampling
description: Repair or review this project's Windows file-capacity guard when native allocation sampling repeatedly times out. Applies to owned sprint storage, not RAM measurement or general filesystem cleanup.
metadata:
  origin: FLW-SkillManager
  source_problem: TD-S20-CAPACITY-SAMPLER-01 / 8090C4AC21AC64D2191046EA91B15A1AA2C04330A298587EB175810BF46235BD
  verified: 2026-10-22 / capacity-calibration01 / FF28ABE8D1AA965D5835614CFD814CADDF06DC1C3F073FAF7CD2D7F842328847
---

# When to apply

Use for repeated capacity-scan failures on this project's Windows owned sprint trees.
This is separate from PostgreSQL document capacity and application/JVM RAM.

# Preserve the metric and limits

Read actual native `FILE_STANDARD_INFO.AllocationSize` and `EndOfFile` from the same
open file handle. Allocation is neither logical length, rounded length, RAM nor
`FILE_COMPRESSION_INFO.CompressedFileSize`. Tiny resident or compressed files may
have zero allocation; preserve the actual value.

The verified minimal implementation is `tools/sprint20/capacity-storage.psm1`:
`GetFileInformationByHandleEx`, class1, sequential24-byte structure, one-byte bools,
EOF offset8 and Directory offset21. Propagate API/invalid-file failures.
The old full witness also queries identity, final path, volume and compression;
do not invoke those irrelevant queries for every file in a capacity-only scan.

Preserve the configured byte budgets, native allocated and logical totals, free
floor and headroom. Sprint20 retained25 seconds/200000 entries,12GiB total,
Root8GiB, free8GiB and512MiB headroom. Future stages use their accepted limits.
Keep reparse refusal and error propagation; only genuinely vanished files under
the exact compiler target may use the existing narrowly scoped exception.
Do not turn repeated failures into successful evidence by extending timeouts.

# Verify a repair before resuming

Review the exact new source and prospective configuration; retain failed captures.
Compare old full witness before/after the new reader on fresh owned benign files:
verified cases were0,1,4096,4097 and1MiB bytes, including actual NTFS compression.
Requested DEFAULT1 is distinct from observed LZNT1=2. Record actual values.
Compare exact small-tree totals, then time the entire real sprint tree under its
unchanged deadline and budgets. A fast enumeration alone proves no native scan.
Report OS-denied symlink creation as SKIP, never as a passed reparse experiment.
Require independent QA/TD actual-result review before resuming affected phases.

# Reduce completed synthetic evidence safely

Compaction is optional and did not alone fix the repeated Sprint20 timeout.
Archive only explicitly identified completed synthetic control directories while
writers are quiescent. Verify every ZIP member length/hash and current original
inventory/hash before exact contained literal removal; retain ZIPs, inventories,
results and scientific baselines. Preserve old roots and failed attempts.
Check reparses within the trusted workspace; do not alter OneDrive ancestors.
This bounded private maintenance is not an adversarial concurrent cleanup API.

# Verified project evidence

`flw/evidence/sprint-20-continuation/capacity-calibration.json` records five native
equivalences and20898 files in10854ms. Independent receipts are
`capacity-acceptance01.json` (QA,E26BEBB2...) and
`capacity-mechanism-closure04.json` (TD,69EEC719...).
Exact source test B33B6C64... and recovery proposal56D8B367... distinguish verified
mechanism repair from final product/public-delivery acceptance.

# Sprint21 transient linker files and incomplete child captures

An actual linker temporary file first refused opening with UnauthorizedAccess
and then vanished. In the exact compiler-target descendant branch only, an
original UnauthorizedAccess may be treated as vanished when a fresh
GetAttributes itself reports FileNotFound or DirectoryNotFound. Existing denied
files, sharing-locked files, outside-target paths and all other errors still fail.
Verified guard895E3558... retains native metric790CF... and25-second limit.

Four actual controls passed: real ReadData denial while present, retained denial
after ACL restoration and actual deletion, outside-target refusal, and actual
ShareNone locking. Fixture window0.2547s; real13273-file scan2.9005s. Acceptance:
`.local/sprint21/qa/transient-guard-acceptance01.json` (QA,A191...) and
`.local/sprint21/td/transient-guard-actual-acceptance03.json` (TD,1ED88C4E...).
A ready marker merely coordinates a deliberate denial fixture after a completed
sample and before the unchanged20-second next check; it skips no budget check.

Compile04's worker was stopped before its build child capture was completed.
That child's historical native exit and EOF remain UNKNOWN even though the
parent capture closed. Preserve the gap and partial streams; never reconstruct
a process.json or infer child EOF from parent EOF. A fresh successful build does
not repair historical coverage, and this guard fix does not solve every capture
lifecycle failure.

# Sprint24 completed public readback copies

A completed Git readback tree may contain later replay outputs in addition to
the downloaded repository. Inventory and archive the complete current tree,
including those outputs, before exact literal removal. Keep the original
download ZIPs, parent receipts and every archive member's original SHA/length.
Do not delete only the Git-tracked subset and assume that the rest is disposable.

Sprint24 archived two explicitly quiescent source copies: 6618 files each,
including251 replay extras beyond6367 downloaded Git files. QA independently
checked all13236 ZIP members and both complete originals before removal.
The subsequent unchanged native guard sampled55611 files in13424ms. This is
one actual observation, not proof of a sole timeout cause or a latency guarantee;
the earlier25-second STOP remains failed. Prefer streaming verification of a
complete downloaded archive and extracting only the declared portable replay
subset, rather than retaining repeated whole-repository extracted copies.

Private source evidence: Root `sprint24/readback-compaction01`, inventory SHA
`705BB536EF79B8BAE1B0B594D5E8172A70ED08227A9A2B76573C312C64FA7E67`;
QA actual acceptance `D53BAE2DB29CFA086113EFAFFFA90FC6FF0B77F6EB1B54247FD257093CD9670E`;
TD actual acceptance `E2C28F38EFF9A209DDF420765BE52540E63256F941C2954EE0C08259025A9D83`.
