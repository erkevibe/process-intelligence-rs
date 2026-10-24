# Fixed-report byte accounting

These observers measure original JSON value slices, not reserialized objects,
RAM, or the size of a hypothetical replacement report. Nested `evidence`
children overlap the top-level evidence value: do not add both levels.

Restore the already published Sprint22 evidence with
`tools/sprint22/evidence-transport.py decode` into a fresh directory (see that
tool's `--help` and [existing replay instructions](../sprint22/README.md)).
Use `DECODED/measurement/http-10k/report.bin` as INPUT. Its exact identity is:
3,222,364 bytes; SHA256
`6E49BE8C6FC36C602B9CB30BBF7F8B11A68E90256FCDACB7431C26ABA3A8F9BE`.
The source is already carried losslessly in
`evidence/sprint22/measurement/http-10k/report.bin.gz`; no second report copy
is introduced here.

With fresh output filenames in an existing writable directory:

```text
python -I -B tools/sprint22-report/account-report.py INPUT NEW_PYTHON_JSON
pwsh -NoProfile -File tools/sprint22-report/account-report.ps1 -InputPath INPUT -OutputPath NEW_POWERSHELL_JSON
```

Check INPUT's accepted SHA256 above before using the PowerShell observer.
The Python observer pins that SHA256 internally and runs manual byte-span
fixtures, including literal versus escaped Unicode and numeric lexemes.
Both refuse existing output files. The PowerShell observer accepts at most
4 MiB; Python additionally bounds direct members and its internal deadline.
They are finite saved-data diagnostics, not general untrusted-archive validators.
Root executed the Python observer with a 30-second external timeout, a 1-MiB
capture cap, isolated Python, and the unchanged workspace resource guard.
It exited 0 with both empty output streams captured to EOF. The separately
executed managed .NET observer agreed on all 29 value sizes and both residuals.
The published result JSON files are exact bytes of those observations.

[Measured findings and future contract](../../docs/REPORT_COMPACTION_CONTRACT.md).
