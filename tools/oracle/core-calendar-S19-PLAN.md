# Sprint19 source handoff: genuine calendar and extended Core filters

Status: source only. No javac/java/cargo/rustfmt or engine invocation was performed by the author. Concrete fixtures were agreed before adapter code: calendar corpus F363E0952BCC8C153B7E269EBA6535787A856A7E8693961FDAEAF6CC77DE347E, extended filters 87D9C3731C66EEDC0BF54FBB7A6652C8B20F507C9A1000F3D0FFEAC46ACFE5D3. No upstream class, fixture, old runner or product library was edited.

## Source files and entry points

* tools/oracle/core-calendar-harness.java -> CoreCalendarHarness
* examples/core_calendar_observer.rs -> core_calendar_observer
* tools/oracle/core-filter-extended-harness.java -> CoreFilterExtendedHarness
* tools/oracle/core-filter-extended-xes-observer.java -> CoreFilterExtendedXesObserver
* examples/core_filter_extended_observer.rs -> core_filter_extended_observer

The Java classes have default-package non-public entry points so their own source filenames do not need to match class names. The XES observer is a renamed byte-content adaptation of the already reviewed OWN typed observer; collection branches retain their specificity before the OpenXES literal superclass. No upstream implementation was copied into an observer.

## Read-only canonical inputs

All paths are relative to the checkout root:

* .local/sprint16/service/runtime-classpath02.txt, SHA256 FAD4762128F2E3120A7A7635B2E2078EE3A24C8D2CCF63C72EB4F628F8753DA3 (ordered real runtime classpath; ~42KiB, use argument files).
* .local/sprint16/service/canonical-build-proof02.json, SHA256 976DB2B8712233ABD6323286E0AD0AD0B0198D74147FC35596A18F13A8BEDD83 (285 actual runtime file pins).
* .local/sprint16/service/bootstrap02/source/Apromore-Calendar/build/libs/Apromore-Calendar-1.0-plain.jar, SHA256 F29983B59677978B95131B02DAA43680921F81FCED061EB85865596C669D2B9A.
* .local/sprint16/service/bootstrap02/source/Apromore-Extras/APMLogModule/build/libs/APMLogModule-1.0.0-plain.jar, SHA256 4FC0C2CDD170C1F5CBF4FE542250C7B84DEB2DFC583DC10631B6562B3894EF81.
* .local/sprint03/oracle/jdk/jdk-11.0.32.1+1/bin/javac.exe, SHA256 9A54EFFE7088D627A433A61DA65D71FB420B5A67D163577C6C4F0EC3DFC3DBD6.
* Same JDK bin/java.exe, SHA256 9FCC7D5D43918E389DF240D44601C98A4D3AA9E7D0CBBD6D208304E0B574C7E2.
* Same JDK lib/tzdb.dat, SHA256 5906B44E25A8A730131D7BA1BEB5D15AF27043F6536F1A169CA8A5D8B8BED8F8; header-only version hypothesis2026b. Runtime ZoneRulesProvider observation remains required.

## Exact compilation plan for Root after QA configuration admission

Create a fresh SID-private .local/sprint19/service/calendar01 with classes/home/temp, console-only logback configuration and new capture directories. Do not reuse S18 writable paths, cached build dirs or expired guards. Use tools/sprint19/phase-runner.ps1 / phase-worker.ps1 and reviewed owned-runtime/phase-support, with the new deadline 2026-10-22T07:39:14Z. Root is the only native compiler/process owner.

Prepare UTF-8 javac.args with one quoted argument per line, escaping backslashes/quotes using the accepted Java argument-file convention:

-proc:none
-encoding
UTF-8
-classpath
<EXACT ordered canonical classpath text>
-d
<NEW private classes absolute path>
<absolute tools/oracle/core-calendar-harness.java>

Actual native command plan:

<JDK>/bin/javac.exe -J-Xmx512m -J-Duser.home=<NEW home> -J-Djava.io.tmpdir=<NEW temp> @<NEW javac.args>

The three own Java sources can also be compiled together into one fresh class directory by listing all three source paths in this argument file; this does not execute either engine. For the optional filter increment compile the two NEW core-filter-extended Java sources with the same options into a fresh filter01/classes. Never place new files in old upstream build outputs. Keep javac -proc:none; do not activate Lombok or other annotation processors. Pin every actual output .class before a separate runtime admission; no compilation success is inferred from source reading.

Per Java case, prepare a fresh argument file with:

-Xmx512m
-XX:-UsePerfData
-da
-Duser.home=<NEW home>
-Djava.io.tmpdir=<NEW temp>
-Djava.util.prefs.userRoot=<NEW prefs-user>
-Djava.util.prefs.systemRoot=<NEW prefs-system>
-Dlogback.configurationFile=<NEW console-only XML>
-Dfile.encoding=UTF-8
-Duser.timezone=UTC
-Djava.awt.headless=true
-classpath
<NEW classes>;<EXACT canonical classpath>
CoreCalendarHarness
<absolute frozen calendar input JSON>
<absolute NEW observation JSON>

Invoke java.exe @case.args through the reviewed assigned-before-GO Job. Filter rows use CoreFilterExtendedHarness and their frozen input/NEW output. Each process <=180s, heap512MiB, each stdout/stderr <=8MiB; require native exit, EOF, full persisted-stream SHA/length, output/capture/drain flags. Reset inherited JAVA_TOOL_OPTIONS/JDK_JAVA_OPTIONS/_JAVA_OPTIONS explicitly; record actual environment/flags. Enforce service logical AND allocated <=2GiB, total<=12GiB, free>=8GiB, hard freeze07:39:14Z. Root must retain separate canonical285/old5763 readback before/after and a final allocation receipt. These source instructions do not admit a native configuration by themselves.

Rust compilation plan (Root's existing isolated Cargo configuration, one heavy window):

cargo build --locked --offline --example core_calendar_observer --example core_filter_extended_observer

Do not alter Cargo.toml/Cargo.lock or product libraries. Root may run standard formatting before recording final Rust source pins. Actual native per-case CLI:

<NEW target>/debug/examples/core_calendar_observer.exe --trusted-corpus <absolute frozen input JSON>
<NEW target>/debug/examples/core_filter_extended_observer.exe --trusted-corpus <absolute frozen input JSON>

Capture exact stdout bytes without JSON number reencoding. Use the same independently reviewed deadline/resource/Job controls and unique fresh output names. Build/version results are unobserved at this handoff.

## Observation ABI

Calendar Java: schema_version/id/input_sha256; actual calendar/workday/builder/factory identities with class SHA/codeSource; main_method and secondary_method; outcome duration|builder_refused|duration_refused; duration_method_invoked/secondary_method_invoked; duration_seconds/nanos/millis and get_duration_millis_secondary; actual java_zone_rules_versions (or separate observation exception); local_start/local_end; full public configuration_before/after_main/after plus hashes/unchanged; full source_input_before/after plus hashes. A builder refusal has explicit unavailable/null configuration/duration fields and real exception chain/stage. Main and secondary calls are never normalized into each other. Private holiday cache changes are not claimed absent; only the recorded public configuration is compared.

Calendar Rust: actual calendar::business_millis once; outcome duration|refused; duration_millis or full original ImportError; IANA_TZDB_VERSION; input SHA; full source_input_before/after and hashes, configuration_unchanged. No local business-duration algorithm or adaptation of Rust gap/fold policy exists here.

Filters Java: exact frozen filter_spec, actual ordered rule fields from real LogFilterRule/RuleValue objects, real whole engine once; selected_source_indices from actual PTrace immutable indexes; selected_event_positions from actual valid-event BitSet; selected_source_log copies only those actual indexed source events, preserving original metadata; source XLog before/after conversion/filter and typed full attributes, full APM snapshots and hashes, source domain before/after. A real converter refusal is recorded separately. Empty PLog results are not converted to ImmutableLog for serialization.

Filters Rust: actual filters::apply once on the complete FilterSpec; outcome filtered|refused and original error; actual selected_source_log; source indices derived from returned unique IDs, event positions from returned exact source Event equality (not a membership predicate); before/after source and hashes; filter_spec_unchanged. Returned empty cases remain empty cases. No exception/result or frozen hypothesis is repaired by an adapter.

The pure comparator must verify actual class/executable/source/input identities and all frozen fields independently. Some source-level numeric hypotheses may fail at runtime; preserve them explicitly. Six calendar main-equality rows plus seven declared diagnostics (precision has equal main duration but a secondary-API diagnostic), and six extended-filter overlap rows plus two diagnostics do not establish complete R5, calendar service persistence, all Core filters, conversions or SplitMiner.
