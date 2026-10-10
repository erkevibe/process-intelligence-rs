# Independent QA corpus

All fixtures are synthetic and owned by qa_process. Expected values come from the specification and hand arithmetic, not app output. Manual fixture includes duplicate trace names to detect unintended merging; variants tied at count=1 must sort AA before AC.

Manual proof: lengths 3+3+2+2=10; A=1+1+1+2=5, B=2, C=3; edges=2+2+1+1=6=10-4. Starts=4, ends=4. Empty trace in semantics contributes one case and empty variant, zero events/edges/starts/ends.

Invalid fixtures must produce semantic/format rejection (HTTP 422), never replace valid analysis. Byte excess returns 413. Invalid view parameter 400 and unknown ID 404 are HTTP checks.

Required generated boundary pairs: bytes 20 MiB / 20 MiB+1 (padding XML comment); events 100000 / 100001; cases 20000 / 20001; activity UTF-8 bytes 4096 / 4097, plus multibyte boundary. Verify valid at-limit and rejected over-limit inputs. These are admission tests, not performance promises.

Benchmark: 1000 cases, 10 events per case, 20 activities; deterministic sequence activity((case+event) mod 20). Capture wall time from actual run and RSS where measurable.

Metamorphic suite: duplicate manual traces (every count doubles); bijective rename to Unicode labels (same graph under inverse mapping); reverse trace order (same analysis); attach then shift offset-aware timestamps (same DFG). Expected outputs must be derived from manual oracle, not current app result.

Integration tests will be added when root supplies public Rust API. Browser checks must independently exercise rapid threshold updates, stable pan/zoom, hidden selection reset, escaped markup, CSP header and valid→invalid preservation of stats/graph/export. No tests executed yet.
