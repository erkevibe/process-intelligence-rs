# R4: prospective genuine-miner cohort addendum

Status: draft for Root, QA, TD, PM and Customer agreement before new cohort bridge/scoring runs. It does not modify the separately agreed quality method, approve a result or close original R4. It prospectively selects all eight existing SplitMiner outcomes for linkage to that method; it does not pretend the already observed miner outputs were unknown.

## Fixed provenance and complete cohort

Use unchanged ApromoreCore `bbf24dfd43e72d6992392465f875a4367cbe792b`, actual SplitMiner class SHA256 `E8535A6B65B7E758A49E757D635E8797071B8E860BC8D1C6859E592EB1EE21AD`, build proof `.local/sprint16/service/miner-build-proof01.json` SHA256 `8649B4D4F2A465954C2F999AA613FD04FF24AA818BB96DDF8390553D8E742D00` and eight-case manifest `fixtures/oracle-splitminer/corpus.json` SHA256 `642254ED2EE675FD4EE2167CE353C75913F0E049AAB681F668DE6184431DAAD0`. Parameters remain frequency0.40, parallelism0.10, WTH, parallel-firstfalse, replace-IORtrue, remove-loop-activitiesfalse, structuringNONE, name classifier.

The actual report `.local/sprint16/service/miner-observer01/reference-results.json`, SHA256 `D95AEB271DB03418F252FFDEC7D09A3EFE1AC758A91B063740DDEF29603A30D4`, and independent `.local/sprint16/qa/miner-finite-independent01.json` bind real original source, classes, dependencies, inputs, native records and all failed/warning outcomes. This is source-aware carry of an actual miner run, not a new execution or a Rust implementation. Old runner paths/deadlines are not a reusable current bootstrap.

| Cohort ID | Immutable exported BPMN SHA256 | Actual carried outcome |
|---|---|---|
| linear | `427E4DBDED59FA732B2CEF5B48AB47A414A4461331BDCC4B19B13DB338C0EAC5` | Returned diagram; original gateway-map ERROR retained |
| exclusive-choice | `887070A89F35C85A315423EF9B30569B220DFA30585A96A06AC39B592032951E` | Returned diagram with explicit XOR gateways |
| parallel-interleavings | `56E33BEEAB413328EB936357BE0B508063D9899FDD5087B96910E4812C715C0D` | Returned diagram with explicit AND gateways |
| self-loop | `CC9F4863586D47B9553D41AAB8EBD7BC797AECA9597D1524C087A3937CC28463` | Returned diagram; task A has `standardLoopCharacteristics testBefore=false` and graph `looped=true`; ERROR retained |
| short-loop | `9705EDDD0B88F25F4ABCA3688696228046C8E99DE0EDB71F4B9E1375025D745A` | Returned diagram with explicit XOR/cyclic structure |
| rare-noise | `E8C27393FB5DEB7739004C7F2AB9C704A116BB5D102DDD0FFFF04E20012AB613` | Returned diagram; actual noise behavior measured, not presumed |
| empty-log | none | Actual `NoSuchElementException`; no net or invented quality scalar |
| empty-trace | `ACA67B5E5D342B39E095A75A1D74023AEBE96947252ADF6B8B99319AEC77FC73` | Returned start/end diagram, ERROR retained |

Raw files are `.local/sprint16/service/miner-observer01/<ID>.bpmn` and `<ID>.json`. New runs read them without changing them. Full synthetic training variants and frequencies come from the paired source manifest and original XES, not a reconstruction from the mined model. The originally observed corpus and hypotheses stay unchanged.

## Required raw-feature compatibility guard

The earlier PM memo incorrectly inferred missing self-loop behavior from absence of explicit cycle edges. The additive correction is `.local/sprint19/pm/miner-carry-correction02.json`; the old memo remains historical. An activity loop is real BPMN semantics, not a diagram annotation. Do not erase it, convert it to an ordinary task, infer a score from the simplified graph or claim the legacy miner lost it.

All seven exports also contain BPMNLabel DI. Current strict product import supports neither that DI child nor standardLoop node children. Consequently raw product-import compatibility, diagnostic semantic-parser compatibility and reference conversion compatibility are separate flags. Passing a diagnostic scorer does not establish strict product import or an operator feature.

Before either converter runs, inventory raw constructs and bind a complete node/flow/attribute map. There is no authorized stripping transformation in this addendum. If annotation-only handling is needed, propose its exact read-only semantics and separate provenance first: original XML bytes remain available, DI/text is execution-inert but retained in evidence, and source graph/task loop semantics remain unchanged. A modified file must never retain the raw file hash or be described as the raw product import.

The exact pinned PM4Py importer/converter source dispatches ordinary Task classes and has no inspected standardLoop handling. Therefore flag self-loop as `quality_unsupported_standard_loop` before import can silently drop it. Current method is unchanged. Supporting it would require a separate prospective loop semantics/reference extension and independent proof. Other unhandled features, deadlocks, growth, final/closure or search limits similarly produce named unsupported/inconclusive results.

## Measurement plan, not expected results

Evaluate the actual immutable outputs, not manually ideal replacement graphs. For each admitted output, save/hash its complete executable net and mapping; compare independently converted BPMN accepting observable automata and then score the exact same saved net in Rust and unchanged pinned PM4Py under the agreed three-metric method. Preserve every alignment, prefix, weighted integer component, structural rational and error. A rejected model has no successful scalar. All eight cohort rows remain in the final matrix; never report a six-of-six result after hiding two refusals.

Report original training-group metrics separately. A zero-event but nonzero-trace group is distinct from an empty evaluation log; method zero-denominator/no-activated policies apply. Training metrics do not prove generalization. To avoid adding an unnecessary new gate, no new diagnostic held-out group is selected by this addendum. If desired, freeze a separate exact manifest of trace IDs, activities, frequencies and source/ground-truth expectations before any cohort measurement; it must openly be newly designated against already observed immutable models, not retrospectively called an unseen pre-mining test.

No target miner-quality threshold is invented after observing results. Exact cross-implementation agreement and manual semantic checks validate measurement; the actual quality values and coverage are reported even if unfavorable. Original R4-02 selected genuine miner evidence and R4-03 evaluator correctness remain distinct. Current missing standardLoop compatibility or any mandatory failed admission cannot be converted into whole-R4 PASS by narrowing the cohort after scoring.

## Decision and completion bounds

This addendum requires actual named Root/Science/QA/TD/PM/Customer agreement before cohort-specific implementation or new execution. Runtime routes, the accepted 0.7.5 product, original R4-01–03 definitions and the agreed metric formulas remain unchanged. No new package/browser obligation is invented for a diagnostic-only contribution; actual affected changes still require their existing independent checks.

Whole R4 requires the original R4-01 AND R4-02 AND R4-03 evidence, exact independent acceptance, current CI and public reproducible source/evidence. A carried genuine miner plus correctly measured admitted outputs can advance that matrix; unsupported loop semantics remains explicit and may prevent full closure. Existing eight-hour deadline, resources, native-process admission and final delivery reserve govern this optional linkage work.
