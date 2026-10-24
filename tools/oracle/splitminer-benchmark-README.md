# SplitMiner benchmark source handoff, Sprint20

Implementation source only, after method2866FEBD and corpus9CB9A9FF agreement. Author did not compile/run Java, the auditor/tests or any miner/evaluator/counter process. Root owns every execution and exact configuration admission.

Compile BOTH new own Java sources with pinned JDK11, -proc:none, UTF8, full canonical miner CP B44143812C83AF2C12299655914A0463EF8DBAF1A700AC1F72426E668C1EE4C5, fresh private classdir and @argfile quoting (the classpath exceeds practical Windows argument length):

* splitminer-benchmark-harness.java -> SplitMinerBenchmarkHarness
* splitminer-benchmark-xes-observer.java -> SplitMinerBenchmarkXesObserver

The typed XES observer is a renamed OWN prior observer, not upstream implementation. No static application object/parser/miner/Jackson is initialized before GO. Java main validates bounded6argument identities and emits BOOT_READY before file/parser/class-identity/benchmark work. Its6CLI arguments are:

INPUT_XES NEW_RESULTS_DIR PROCESS_ID CASE_ID NONCE cold|warm

PROCESS_ID is cold-r[1-3]-CASE_ID or warm-CASE_ID exactly. NONCE is16-128ASCII alphanumeric/hyphen characters. Boot stdout protocol line:

S20_PROTOCOL {"phase":"BOOT_READY","pid":ACTUAL,"nonce":"...","process_id":"..."}

Root sends exactly GO NONCE newline through kept-open stdin only after owned Job assignment/identity checks. Application work starts after that accepted line. The resultdirectory is a NEW private child, not a directory containing existing benchmark artifacts. It may be Root-created empty or harness-created under a private parent afterGO. All artifact writes use CREATE_NEW; ledger is atomically created before its append writer is opened.

Cold runs one measured call. Warm runs exactly two warmups then three measured calls. Frozen call IDs are PROCESS_ID-warmup-[1,2] and PROCESS_ID-measure-[1,2,3], cold uses measure-1. Every call gets fresh parser/XLog/miner/classifier outside engine interval. Actual method nanoTime delta is captured in finally even on a caught Exception. GC diagnostics cannot mask the method result and do not invoke GC. Parse/constructor/observer/export errors have distinct stage/status. Fatal Errors propagate and leave partial forced ledger/native evidence; Root fills missing scheduled-call statuses from the immutable schedule, never zero-imputes a call.

Outputs: each CALL_ID.json, every actual CALL_ID.bpmn (including partial failed-export artifacts, marked separately), iteration-ledger.jsonl (started/completed records), summary.json, terminal-ready.json. Every own JSON writer closes/forces; upstream BPMN export is closed then forced/hashed. Successful graph output includes richer activity/event/gateway/containment/flow fields, but full exported XML remains semantic authority. Loop children/conditions are never removed to fit quality evaluation.

Terminal stdout is S20_PROTOCOL JSON with phase TERMINAL_READY, actualpid/nonce/process_id, counts, terminal-ready artifact and summary/ledger descriptors. Root must verify those actual hashes/bytes/identities while the process is alive, then query process-lifetime and Job-assignment counters, persist its receipt and send exactly EXIT NONCE newline. The harness performs no more engine/export work after terminal-ready. Unexpected EOF/nonces cause a native failure. Control line reads are bounded512ASCII bytes; protocol/status output uses stable prefixes, while every upstream warning/error console byte stays in the Root capture. Complete native streams cannot be inferred merely from seeing a sentinel.

Main memory is native lifetime PeakWorkingSetSize/PeakPagefileUsage, not Xmx or sampled maxima. Warm memory covers startup+bothwarmups+allthree measurements+allparses/exports/observer, never percall. Process lifecyclewall includes both gate holds; active_pipeline_nanos covers acceptedGO through forced summary, excluding terminal-control metadata writer. Root must retain its independently clocked gate/pipeline/lifetime counters without subtracting different clocks.

Pure semantic auditor API (Root-owned execution only):

python -B tools/oracle/audit-miner-performance.py --baseline HISTORICAL_RAW.bpmn --candidate NEW_RAW.bpmn --output NEW_AUDIT.json
python -B tools/oracle/audit-miner-performance-tests.py

The generic auditor checks every semantic XML element/attribute/literal text and all ID/ref/containment relationships under an exact full bijection. Only named DI/DC layout subtrees and ID spelling are excluded. Incoming/outgoing and declared process-flow collections are unordered; loop/expression child structure is preserved. Unknown semantic namespaces, unresolved references, DTD/entities or exhausted limits are not ignored. Color refinement prunes candidates; final literal vertex/all-edge multiset equality under the COMPLETE map is the proof, never just hashes/counts. Excluded-layout hashes are explicitly hashes of parsed subtree serialization, not fabricated original raw byte spans; complete rawXML hashes/files remain authoritative.

Output semantic_equal and semantic_carry_gate_passed are necessary semantic gates only. quality_carry_permitted stays FALSE because this generic tool does not independently establish the historical same-case metric/net/admission binding. Root's cohort auditor must additionally enforce the6admitted-source-quality allowlist and complete S19proof binding. Self-loop/empty-log never acquire scalars from this flag. Candidate runtime/status/warnings remain actual even if graphs differ; timing rows cannot be discarded or replaced with a favorable repetition. All56expected diagrams (7cases*8calls) need separate maps; the8empty-log calls keep their actual exception/no-BPMN outcome.

Ten offline test methods are authored: sevenhistorical originals, completeUUID/prefix rename, DI-only changes, label/count trap, loopflag/loopchild/removal, conditions/endpoints, activity/event/process attributes, duplicate/danglingIDs, unknown namespaces and forcedbudget-inconclusive. They are source tests, not executed results or miner evidence. OptionalAlpha remains disabled; no Rust example is authored as a fake SplitMiner implementation.
