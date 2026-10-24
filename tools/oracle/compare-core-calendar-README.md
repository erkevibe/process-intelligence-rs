# Sprint19 pure calendar and extended-filter comparisons

Source-only handoff, before actual R5 results. Neither comparator implements a duration/selection predicate. They consume the complete raw observations, actual executable/class identities and closed bounded native-process records. Observations and native-record paths are relative to each index JSON directory. Every index case requires id/input_sha256/observation_path/observation_sha256/native_record/native_record_sha256, in the frozen corpus order. Top-level corpus_sha256 is mandatory; runtime_bindings metadata may be retained separately.

Root-owned pure commands after native observations exist (Node24 numeric-source JSON support):

```
node tools/oracle/compare-core-calendar.mjs JAVA_INDEX RUST_INDEX NEW_REPORT
node tools/oracle/compare-core-filter-extended.mjs JAVA_INDEX RUST_INDEX NEW_REPORT
node --test tools/oracle/compare-core-calendar.test.mjs tools/oracle/compare-core-filter-extended.test.mjs
python -B tools/oracle/core-calendar-public-projection-tests.py
```

The tests are counterfactual field-check unit tests, not observations of an engine. They test lost precision, mutation, event order, diagnostics and preservation of a successful main duration after a secondary-only exception. They are authored but not executed by this source author; Root owns commands and captured results.

Fixed inputs: calendar13 manifest F363E0952BCC8C153B7E269EBA6535787A856A7E8693961FDAEAF6CC77DE347E; filters8 manifest87D9C3731C66EEDC0BF54FBB7A6652C8B20F507C9A1000F3D0FFEAC46ACFE5D3. No expectations are retuned. CLI checks actual per-case native executable SHA: Java9FCC7D5D43918E389DF240D44601C98A4D3AA9E7D0CBBD6D208304E0B574C7E2, calendarRustDAB02678C7B216F85C4C8279C3757E428C571FE3AE88FFD1EC85083AD70C78D4, filterRust2F821090681E72E925E46059DDFF6C986CF232504EA6F3A6D075C1F7CCEA313C. A future rebuilt executable requires an explicitly reviewed new pin, not a silent bypass.

Calendar main success is derived from actual invocation and retained seconds/nanos/milliseconds; an outer duration_refused caused by the separate rounding API does not erase that main result. Secondary error/class/value is reported separately and can fail its frozen hypothesis while main-duration equality remains true. Full public configurations and inputs are compared before/after. Actual Java local endpoint offsets and UTC instants are checked independently against a source-frozen table: UTC0, Kathmandu20700seconds, Berlin spring3600-to7200/fall7200-to3600. Actual tzdb versions are recorded/checked separately and never excuse a wrong offset. Rust does not expose direct offset observations in the already compiled diagnostic: that limitation is explicit; its real business duration is checked against the frozen independently derived UTC segments. No secondary result is substituted for the main API.

Filter comparison checks every frozen field, complete selected source EventLog, actual trace/event source positions, pointer identity, full source XLog/APM/domain conservation and actual ordered rule parameters. Long.MAX_VALUE is parsed/compared/serialized as an exact integer, never rounded by ordinary JSON.parse. Empty-case and reversed-range diagnostics remain differences rather than equality PASS. A failed hypothesis is retained in a report with an explicit differing status; source identity or native-capture failures abort instead of receiving partial PASS.

Public field projection, only after actual raw indexes and comparison are pinned:

```
python -B tools/oracle/core-calendar-public-projection.py --profile calendar --java-index JAVA --java-index-sha SHA --rust-index RUST --rust-index-sha SHA --comparison REPORT --comparison-sha SHA --output NEW_DIRECTORY
```

Use --profile filter-extended for the other corpus. The projector retains every JSON numeric lexical token, all original local raw inputs, original hashes separately from sanitized hashes, exact frozen fixture backups, and native exits/EOF/byte hashes. It publishes normalized full synthetic JSON observations and verified process records; raw console streams are not copied. CodeSource/program/runtime binding paths are replaced only for the checkout root or explicitly reviewed --local-root ALIAS=ABSOLUTE_PATH declarations. An unmapped absolute path aborts. Public indexes use relative paths to their own directory and preserve optional runtime_bindings. Independent QA must regenerate the new public tree and replay the pure comparison; no existing directory is overwritten. The manifest inventories every product except itself and records the source-transform SHA.

This does not start Java, Rust, Cargo, services or a native replay. No expired deadline/guard is bypassed. No full calendar/Core/R5, conversions or SplitMiner parity is claimed.
