# Sprint04 independent Customer preplan position

Owner /root/customer, fixed Customer seat. Start14:57:49UTC/deadline22:57:49UTC supplied by coordinator; eight-hour budget includes planning/failures/verification/delivery. Read current ROADMAP, SPRINT_03_REPORT and remaining SCALE01 debt. No runtime changes or acceptance vote. Existing3000/3010/3030 user apps and sharedPG5433 must remain untouched.

## Fact, value and risk

Accepted0.3 now fails safely when a whole-project JSONB container fills, but cumulative cloning/writing/startup validation remains expensive. Valid imported data previously reached real container limits and debug reopen timeout. Separate log/model records remove this structural bottleneck only if actual operations stop loading/cloning unrelated records; table creation alone does not deliver customer value. The user value is reliably opening accumulated work and editing one model/log without paying for the whole project, while upgrade preserves access and job outcomes.

## Prioritized Customer acceptance

| ID | Priority | Proposed scenario and actual acceptance |
|---|---|---|
| S4-C01 | P0 | Strict NEW restored actual0.3 store→exact0.4 first migration; old0.3-issued session, users/roles/memberships, two same-name logs/IDs/source hashes/full exports, filters/calendar/views, models/geometry/revisions and job result links survive. Existing user store is never used as migration test. |
| S4-C02 | P0 | Versioned migration transactional or explicitly resumable with per-step durable state. Actual process kill/fault during record conversion leaves usable old or complete new contract; repeat migration never duplicates/loses records. Future/checksum/unknown supported-schema violations refuse without writing. |
| S4-C03 | P0 | One log/model edit touches only that record plus justified small metadata, preserving other complete hashes/revisions. Permission checks cover direct normalized-record known IDs; no viewer/foreign-project write/read/export/job bypass. Source immutable semantics remain intact. |
| S4-C04 | P0 | Log result+completed and accepted cancel/failed transitions remain atomic/durable after normalization. Actual queued/running crash, acceptedcancel immediate restart, missing/orphan result and compare-and-swap conflict tests must not advertise unsaved success. |
| S4-C05 | P0 | Replay SAME unreduced cumulative six-log/capacity input from0.3 plus fixed aggregate corpus. Old exports stay identical; import previously refused by whole-project capacity either succeeds with exact expected result under new contract or explicitly remains limited. Do not reset/split the test solely to claim improved capacity. |
| S4-C06 | P0 | Actual cold reopen/list/open-one-log/model-edit/import timings and process memory observed on fixed inputs/hardware/release mode; before/after executable/source/hash identities distinct. RSS or Windows working-set label is precise. Failure/unknown target reported, no general speedup from one measurement. |
| S4-C07 | P0 | DB-level backup→new restore includes schema/auth/normalized records and preserves exports/access/jobs. Corrupt/existingtarget/partial failures preserve source. Project backup versioning has explicit backwards compatibility/rejection, never drops records silently. |
| S4-C08 | P0 | Frozen clean package/nativePS5 start, prior R1/S2/S3 regressions, independent QA/TD, actual CI/public anonymous ZIP hash and untouched live installs required. Separate artifact versus delivered status. |
| S4-C09 | P1 | UI shows same familiar logs/models and honest storage limits; no raw new schema details required from user. Where aggregate limit changes, clearly distinguish per-import/record/project limits and why a rejection occurs. No unnecessary remapping/reimport during upgrade. |

## Scope and risk appetite

Prefer this storage/recovery/measurement sprint over additional BPMN or oracle breadth. Medium portfolio appetite; low for user data/access/migration and honest performance claims. Freeze measurement corpus/targets and migration cutover contract before code. Preserve final90min for independent replay/package/delivery. P0 failure blocks affected storage release; independent successful UI cannot compensate. Existing0.3 remains available,0.4 installs separately until user migration is explicitly performed outside these isolated proofs.

SCALE01 can be narrowed/closed only for paths actually changed and measured. New tables while eager whole-project cache/clone remains is not full closure. No promise of all64projects/eightmaxlogs/enterprise throughput without actual aggregate evidence. Threshold improvements should not come from larger timeouts, smaller inputs, dropped history or relaxed integrity checks.

## Control cost and continuity

Keep cheap route/module/port/selector/old-session preflight and one immutable attempt manifest. QA owns independent fixtures/replays; Root owns runtime integration; TD audits source/storage boundaries. Reuse unchanged passed checks proportionally, rerun changed durability/migration paths and final exact-package gates. Historical failures remain; documentation edits do not require another full heavy corpus run. Await actual separate PM emotional perspectives and exact proposal; no vote is implied by this position.
