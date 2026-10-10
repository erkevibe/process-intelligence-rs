# Independent Sprint03 CI audit

Frozen source: `89cdcbcef5c988ff46716bb0e1ae16e8c2334e6a`.

Push run [38052542884](https://github.com/erkevibe/process-intelligence-rs/actions/runs/38052542884) actually checked out this exact source. PR run [38052547066](https://github.com/erkevibe/process-intelligence-rs/actions/runs/38052547066) actually checked out generated merge SHA `4d30a19ba1c39afe745ea2b0d329fc911fadd137`; its head metadata must not be presented as identical checkout/artifact identity.

Both available full Linux job logs show formatting, clippy with warnings denied, tests, optimized release, local ephemeral health smoke and artifact upload completing. Each has **57 ordinary passing tests and 9 explicitly ignored real PostgreSQL tests** (S2 platform2, S3 storage7). The smoke starts `PI_EPHEMERAL=1` and requires health status ready. This proves ephemeral startup on Linux; it does not test real PostgreSQL, Windows installation, recovery faults, or browser interaction. Actual local frozen realPG7 and fresh S2 realPG2 passed separately in private final logs.

Coverage: independently loaded all 12 available downloaded files for each run as complete byte snapshots and recorded size/SHA256 in `sprint-03-ci-audit.json`. Compiler/test/health/upload command/results and checkout identities were semantically inspected using bounded selected output. This is not complete semantic review of every setup-machine line or unseen runner state. The health body itself is not printed in raw step logs; successful smoke enforces its ready check. No raw credentials, request headers, tokens, or signed/download URLs are published.
