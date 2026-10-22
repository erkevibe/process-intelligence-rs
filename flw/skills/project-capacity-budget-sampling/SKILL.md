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
