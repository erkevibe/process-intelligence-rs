# TD prospective fingerprint optimization approval

Disposition: GO for the narrow measured source optimization only; not full Apply acceptance. Actual UTC recorded below.

Read exact QA scripts analyze-full-fingerprint02.ps1 and fingerprint-utc-values03.ps1, analyze-full01-results.json, analyze-full02-results.json and analyze-full02-safe-result.json. Native ANALYZE and values runs report exit0 with unchanged statement5000/lock2000/transaction10000. QA reports actual workers3,128 full fingerprint rows, UTC-corrected exact PRE equality and separate sequence unchanged. TD read the full query and metadata; complete128-row equality here is attributed to QA, not claimed as independently recomputed. Prior timezone/log_cnt mismatch captures remain preserved.

Approved delta: unchanged complete count/MAX_ROWS and key512 guards; four SET LOCAL planner settings only; all five fully public-qualified branches in MATERIALIZED fingerprints UNION ALL produce identical tagged scalar fields and full encode(sha256(convert_to(document::text,UTF8)),hex) domain. Deterministic table/key ordering, bounded rows returned to leader, no heavy document transfer. Existing exact typed sequence query remains separate and unchanged. Schema accepts only ledger1/2, so version::text ordering is equivalent to original numeric ordering in the admitted schema; no future arbitrary-version claim.

Both source/restore locks and exclusive transaction pairing remain; complete PRE and POST pairs, all managed rows/values/versions/markers/ledger times/sequence, exact DELETE RETURNING and single source commit remain. Error/panic/no workers/timeout cannot produce committed success. No SQL/lock/transaction extension, sampling, cached checksum, xmin or versions-only shortcut, new schema or global settings.

Actual final full unreduced optimized Apply must prove PRE+DELETE+POST within the unchanged transaction budget and unchanged restore/all other data before acceptance. Successful isolated SELECT timing does not establish whole Apply feasibility or guarantee workers on another run. Owner cleanup developer; independent QA and final candidate gates still pending.
UTC: 2026-10-11T09:59:11.0080970Z
