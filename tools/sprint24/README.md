# Sprint24 observation tools

`current-api-http.py` and `operations-http.py` exercise the finite synthetic
profiles described in `docs/SPRINT_24_REPORT.md`. They are test observers for
isolated local fixtures, not instructions to run against an existing user DB.

`runtime/` contains byte-identical snapshots of the reviewed private runners
and protocol rules. Actual executions used the original private paths and
SHA-pinned configurations; passwords, session cookies and runtime configuration
values are omitted from publication. The snapshots are not a standalone
deployment launcher. Native process labels inherited from earlier harnesses
(for example `app10k`) do not imply a fresh 10k-event experiment; the capacity
runner uses these aliases for explicitly named psql controls only.

For an existing PostgreSQL 18 installation, the operator-facing utility is
`capacity-diagnostic.sql`. See `docs/CAPACITY_DIAGNOSTIC.md` for connection,
completion-marker and measurement limits.

To check the published saved observations from the repository root:

```text
python -I -B tools/sprint24/check-saved.py evidence/sprint24/saved
```

This repeats file, journal and descriptor consistency checks of saved data.
It does not start the server, repeat the original API assertions or prove
enterprise readiness. The manifest separately records original and public
file identities. Literal local user-home prefixes are replaced in public
representations; original native capture SHA/length fields remain original.
Numbers, including 18-digit FILETIME values, retain their original lexemes.

`check-journal.py` checks only durable-journal control cases without HTTP.
`runtime/ops-protocol-controls02.ps1` checks only pure PG-generation rules,
without native timers or PostgreSQL. `project-saved.py` creates a bounded
explicit selection from privately pinned originals; its private config is
not an operator API or part of the published evidence.
