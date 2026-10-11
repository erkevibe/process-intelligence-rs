# Alpha+++ developer contract — optional Sprint08

Contract proposed before implementation at actual 2026-10-11T03:51:24Z; forty-five-minute feasibility window ends04:36:24Z. Root and prospective QA accepted the bounded scope before code. Root coordinated draft test03 completed successfully before the gate; independent exact-candidate QA/TD and delivery remain mandatory. This is a separately named genuine Rust4PM Alpha+++ adapter, not Split Miner, BPMN conversion, model quality acceptance or production HTTP integration. Mandatory operator-preview/IANA delivery retains priority.

Use locked process_mining0.6.2 MIT OR Apache-2.0 API `discovery::case_centric::alphappp::full::alphappp_discover_petri_net`, direct real `EventLogActivityProjection`, original PetriNet output. Local locked source is primary evidence; attempted docs.rs versioned API read was unavailable, not verification success. [Versioned primary API](https://docs.rs/process_mining/0.6.2/process_mining/discovery/case_centric/alphappp/full/fn.alphappp_discover_petri_net.html).

Finite developer admission: at most6 distinct activities,500 events,64 traces and32 variants; each activity nonempty≤200bytes; reject reserved `__START`, `__END`, `__SILENT__` prefix. Empty traces/log rejected rather than silently removed. Source log is borrowed and never changed. Deterministic sorted activity/variant projection preserves weighted counts but timestamps/lifecycle/source attributes are deliberately not discovery input. All limits checked before algorithm; a selected projection with integer variant weights is required, never fabricated No Activity labels.

XML1.0-illegal label characters are refused before PNML export. Source newline/tab and Unicode remain subject to valid XML character rules; reserved internal labels are not accepted as user activities.

Pinned explicit config (not automatic upstream defaults): balance_thresh1.0, fitness_thresh0.0, replay_thresh0.0, log_repair_skip_df_thresh_rel10000.0, log_repair_loop_df_thresh_rel10000.0, absolute_df_clean_thresh1, relative_df_clean_thresh0.0. With≤500 events these high repair thresholds prevent observed paths qualifying for loop/skip repair in the inspected implementation; this is a deliberately restricted developer configuration, not verified general loop/noise capability. Public caller cannot supply arbitrary config in this iteration.

Output: real PetriNet JSON and PNML via upstream `export_petri_net_to_pnml`; report algorithm/version/config/admission/input SHA separately. PNML import/reimport may be checked using real upstream importer for labels/arcs/markings; UUID byte equality is not required because upstream UUID creation is nondeterministic. No BPMN rewrite, no graph placeholders, no HTTP persistence/cache/jobs wiring. CLI output goes to a fresh named file because upstream discovery prints progress to stdout; stdout is not presented as clean JSON.

Cancellation checked before projection, between projection cases, immediately before and after upstream invocation. Upstream single invocation cannot be interrupted midalgorithm; this limitation is explicit. No thread/process kill or live jobs promised. Developer example only, no arbitrary untrusted production discovery requests.

Frozen manual cases before actual run: sequential20×[A,B,C]; choice20×[A,B,D] plus20×[A,C,D]; concurrent20×[A,B,C,D] plus20×[A,C,B,D]. Expected literal source counts/activity labels/variant frequencies fixed. Test-only bounded weighted-token firing checks visible complete sequences: sequential accepts ABC and rejects BAC/AB; choice accepts ABD/ACD and rejects ABCD/AD; concurrent accepts ABCD/ACBD and rejects ADCB. These are selected model-behavior assertions with silent-transition closure and state/step caps, not measured fitness/precision or proof of soundness/general language. Failure means optional contract failed and is not hidden by checking counts alone. Algorithm observations also include actual place/transition/arc and initial/final marking validity, no activity invention. Negative admission: empty, reserved labels,7 activities,501events,65traces,33variants and cancellation. Quality fields are absent, not fabricated zeros/ones. Independent QA evaluates actual algorithm call/projection/conservation/PNML output and supported assertions; training fit1 or config fitness_thresh is not measured fitness. Upstream panics are caught at the adapter boundary and reported as refusal; this does not provide midalgorithm cancellation.

Implementation owners: PM src/discovery.rs, standalone developer example and dedicated fixtures/tests only after scope review. Shared lib/Cargo/platform/bpmn changes belong to Root. Optional code stops at feasibility timeout if real build/API/export cannot be demonstrated safely. R4-01/BPMN and R4-03/quality remain OPEN; R5-04/Split Miner remains OPEN regardless of this adapter result.

## Draft execution and reproduction

Frozen manual corpus SHA256 `A24010FCCD0ECA0F2DF6C7F243DC35E2186AE6BB9E8DF3FC08074020A14589CD` predates algorithm execution. Root draft source `6d153198dca6b801580b45fb6795aea709235417` includes this adapter; coordinated test03 ran two discovery tests successfully, including all three actual mined outputs, weighted complete-sequence assertions and real PNML round trip. This is author/Root draft evidence, not independent final acceptance.

Test01 failed on incorrectly imported private Petri type paths; corrected to actual public reexports. Test02 reached the real algorithm and failed a test-oracle UUID-equality assertion. Actual upstream importer creates fresh UUIDs for places/transitions, so that assertion contradicted the intended ID-independent contract. The repair compares a full bijection of labels/tau, weighted multiedges and initial/final markings, followed by the unchanged positive/negative complete-sequence assertions on both original and reimported net. Isomorphism node/search caps and token state/step caps fail as inconclusive/test failure, never count-only successful equality or rejected-language proof. Corpus and pinned algorithm config were not altered to fit the outputs.

Build example with the existing pinned workspace toolchain, then run:

```text
cargo test --locked --test sprint08_discovery
cargo run --locked --example discovery_alpha -- INPUT_EVENTLOG_JSON NEW_OUTPUT_JSON
```

Input is the existing EventLog JSON representation; example input byte limit1MiB plus semantic caps above. Output file uses create-new semantics. Upstream progress prints stdout; actual result is the named JSON file containing real PetriNet and PNML. No JSON-byte reproducibility promise because UUIDs vary. Config, algorithm/version and source hash identify the run; general model fitness/precision, soundness and arbitrary loop/noise quality remain unverified.
