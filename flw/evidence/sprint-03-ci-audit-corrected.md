# Independent corrected-candidate CI audit

Candidate runtime source: a0b4f6989825de47c48d1d6ab8e1cedbac19c017. All 24 available downloaded files (12 per run) were completely loaded and fingerprinted; file inventory and exact hashes are in sprint-03-ci-audit-corrected.json. Compiler, test, health and upload steps were independently inspected in bounded excerpts. This is complete downloaded-file machine coverage, not every runner operation's semantic certification or missing external logs.

Push run 38054672102 actually checked out a0b4f6989825de47c48d1d6ab8e1cedbac19c017. PR run 38054674511 actually checked out generated merge b1d18b79d67943e4c88fe8683ed4054b76c8c58c; it is separate merge CI evidence, not identical frozen artifact evidence.

Both logs show fmt check, clippy all-targets with warnings denied, 60 ordinary tests PASS and 10 explicitly ignored real-PG tests (2 S2 platform + 8 S3 storage), optimized release build, successful ephemeral health smoke with ready-status grep, and completed artifact upload. No compiler warning/error or failed test appeared in these inspected sections. Health JSON contents were not printed; successful step enforces ready via grep. Real PostgreSQL tests, Windows setup, browser and crash/recovery were not run by CI and receive no CI acceptance credit.

Raw signed URLs, headers and credentials remain private. Historical rejected-source89 audit remains separately retained.
