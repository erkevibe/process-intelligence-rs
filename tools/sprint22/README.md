# Sprint22: saved evidence and process ownership

The Rust application remains the existing 0.8.1 candidate. The new Windows
broker owns native handles and redirected captures outside the worker Job.
It records identity and capture readiness before resuming a suspended child.
STOP denies further admissions before terminating the existing Jobs.
Collector or host death remains outside this guarantee.

The runtime scripts require the private, pinned local configurations used for
the experiment. They are not a portable service installer. Do not reconstruct
credentials or rerun an expired configuration from this repository.

## Public replay

`evidence-transport.py decode` restores the logical evidence tree into a **new**
directory inside the workspace. Gzip is transport only: compressed hashes and
decoded hashes are separate. The decoder rejects altered bytes, trailing or
concatenated gzip members, traversal, collisions, and unexpected files.
It keeps the existing whole-source download limits unchanged.

After decoding `evidence/sprint22` into a fresh private directory `DECODED`,
the saved-data auditors accept these arguments:

| Script | Arguments |
|---|---|
| `audit-public-controls.py` | `DECODED/core NEW_OUTPUT_JSON` |
| `audit-adapter.py` | `DECODED/adapter NEW_OUTPUT_JSON` |
| `audit-public-measurement.py` | `DECODED/inputs DECODED/measurement NEW_OUTPUT_JSON DECODED/projection-manifest.json` |

`audit-public-projection.py` checks `DECODED NEW_OUTPUT_JSON` with
`--policy tools/sprint22/project-public-evidence.py`,
`--policy-sha E29223B3CB01729BAB84A1979D80C6F7EAEE1A8CCAF6EE90C4FDAD8DD2EBFB88`,
`--selection-sha 024B8F6290A0CE26589D2140F549B0E2B42BFE9D9467082873BD2BC486FFC50E`
and `--bundle-kind primary`. For the uncompressed `evidence/sprint22-process`
tree, use selection hash
`C0C4CC155DD22649DC96A3512A31D02F437C4DBD24AC8BEBFFDC4C96F730FFAE`
and `--bundle-kind process`. Public replay does not use `--workspace` on
the auditor: private original observations are unavailable in the download.

Auditors read saved data; they do not launch the application or PostgreSQL.
The adapter auditor deliberately accepts the three fixture observations while
requiring the **whole adapter phase to remain failed** at its final guard.

The measurement auditor distinguishes a completed 10,000-event conversion
from the actual `report_byte_limit` refusal at 90,000 events. Both refused
downloads were 404; the original source persisted. These are fixed repeated
events, not a graph-diversity or general performance benchmark.

One public native output, `measurement/session/cluster-identity.stdout`, has
an explicit path alias. Its original native capture descriptor keeps the
private raw SHA and length. The projection manifest separately binds the
published representation; the other 27 measurement streams retain exact
original bytes. Private credentials and setup request bodies are omitted.
All science inputs, successful output/report, SQL snapshots and memory lines
remain exact decoded bytes. PostgreSQL maintenance archives are private.

`check-projection-controls.py` requires the retained private observations.
It checks the narrow path/URI policy and does not claim a fresh product run.
See [the sprint report](../../docs/SPRINT_22_REPORT.md) for acceptance limits,
historical failures, and remaining R5 work.
