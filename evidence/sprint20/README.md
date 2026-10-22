# Sprint20 portable evidence

All inputs are synthetic. `conversions` contains all 57 frozen forward cases
and 16 separately executed inverse calls. `conversion-boundaries` contains
nine real external-file and failure probes, including the actual 20 MiB + 1
zero-byte input and unchanged sentinel. Malformed scientific JSON inputs are
preserved byte-for-byte, not parsed or repaired by the publisher.

`miner-performance` retains all 32 actual JVM processes and 64 calls, including
warmups and exceptions, raw BPMN, complete ledgers, OS memory/CPU counters and
independently extracted runtime-class pins. No upstream JAR or class binary is
redistributed. Six historical quality rows are carried only after all 56 full
semantic BPMN maps pass; these are not newly measured quality scores.

Local filesystem paths are replaced only in explicitly permitted metadata.
`public-projection.json` inventories every included original/published identity
and all ancillary omissions. The independent original-to-public audit verifies
scientific fields, order, exact number lexemes, and opaque payload bytes.

For each JVM, `benchmark.raw.stdout` and `benchmark.raw.stderr` are the complete
original capture bytes. Original native-record counts and hashes describe
those raw files. `benchmark.stdout` is separately identified projected protocol:
only the three terminal artifact descriptors may change. BOOT, process identity,
nonce and all other console bytes remain unchanged. Ordinary converter streams
are unchanged and continue to be checked in full. Original build/runtime/class
identities remain distinct from the path-projected compiler-proof identity.

Saved `*-audit` reports retain their historical source identities. Fresh replay
uses these published files and produces new receipts outside this evidence tree;
local acceptance receipts are in `flw/evidence/sprint-20-qa`. Ancillary failed
logs, intermediate checkpoints, argument files and synthetic negative-control
clones remain private; the projection map explicitly lists omitted file hashes.
The drivers reproduce retained-clone controls from the included raw datasets.
Cloned process records never count as additional native invocations.

`manifest.json` inventories every published evidence file except itself. Only
root `manifest.json` and this README are allowed outside the projection map,
which avoids a cycle between the two manifests. The frozen method documents
keep their original DRAFT names and bytes. Run the pure inventory and evidence
auditors from CI using fresh output paths outside this evidence directory.
These audits require Python's standard library and execute no Java miner,
Rust metric engine, database or web server. The reusable converter is built
from `examples/pi_convert.rs`; see `docs/CONVERSIONS.md`.
