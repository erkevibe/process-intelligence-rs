# Compact conversion reports

Compact reports are an explicit transport option for XES ↔ CSV conversions. The
default report remains schema 1. A compact report contains the complete schema-1
JSON, compressed without omitting cores, event order, warnings, or evidence.

CLI usage:

```text
pi_convert xes csv input.xes NEW_OUTPUT_DIRECTORY --compact-report
pi_convert csv xes payload.csv NEW_INVERSE_DIRECTORY --compact-report
```

The conversion form exposes the same option, initially unchecked. Compact
reports require a decoder; they are not directly readable event summaries.

Decode the complete report into a new file with Python 3:

```text
python tools/sprint23/decode-report.py report.json NEW_DECODED_REPORT.json
```

Keep `audit-compact.py` beside the decoder. An optional `--codec-sha SHA256`
checks the expected codec source identity. Without it, decoding verifies framing
and integrity but does not authenticate provenance. The output file must not
already exist.

## Limits and integrity

The stored report limit remains 4 MiB. The decoded JSON limit is 64 MiB. Input
and output files remain limited to 20 MiB. Compression does not enlarge these
limits or extend the supported conversion profile.

Schema 2 uses the `gzip-hex-report-v1` profile with seven fields:
`schema_version`, `report_profile`, `inner_schema_version`, `codec_sha256`,
`decoded_bytes`, `decoded_sha256`, and `data_hex`. The inner schema is 1.
Decoding checks the declared length, SHA-256, canonical gzip header, CRC,
single-member framing, and unique JSON keys. A codec source hash identifies
provenance; it is not a signature or an authorization mechanism.

## Existing data and rollback

Existing schema-1 artifacts are read without rewriting their bytes. Compact
jobs persist an explicit report capability in their metadata, including while
queued, cancelled, or interrupted.

Before the first compact job, take a full PostgreSQL backup. An older binary
that does not recognize this metadata refuses startup of the whole platform
when it encounters such a project. Restoring a project through the application
does not undo that capability. Rollback requires restoring the full database
backup into a separate database and starting the older binary against it.

## Validation scope

Transport integrity alone does not prove conversion correctness. Acceptance
also checks the actual input and payload, every ordered event field, all report
evidence, and a real inverse conversion. A successful CLI run does not establish
web workflow, restart, cancellation, or historical-binary compatibility; those
have separate acceptance checks.
