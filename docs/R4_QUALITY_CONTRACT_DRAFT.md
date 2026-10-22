# R4 quality: prospective contract for Sprint 19

**DRAFT — no implementation or acceptance approval.** Original R4-01–03 remain the criteria in `SPRINT_08_SCOPE.md`. This proposal adds genuine Petri/BPMN evidence; it does not convert Sprint 18 Alpha fitness into BPMN quality, close discovery, or replace missing criteria with a percentage.

## Semantics before scoring

Keep the existing BPMN import/edit/export language unchanged. Quality evaluation has explicit admission: one start and one end; start/end and ordinary tasks have their appropriate single input/output; task activity labels must be nonempty; gateways are explicit exclusive or parallel. Multiple incoming/outgoing ordinary tasks and multiple starts/ends remain valid editor data but receive an explicit `quality_unsupported_semantics` response until their semantics are agreed. Never silently treat an unnamed task as invisible or a multi-output task as a choice.

An initial proposed bridge uses one place per sequence flow and source/sink places. A task is a labelled transition consuming its input-flow token and producing its output-flow token. An XOR gateway gets a silent transition for every input/output pair, consuming one selected input and producing one selected output. An AND gateway gets one silent transition consuming all inputs and producing all outputs. Mixed split/join gateways apply these same rules. Start/end connect source/sink with silent transitions. Initially only source has one token; final marking contains only sink. Flow/gateway labels are annotation. Conditions/default flows, inclusive/event gateways, subprocesses and extensions remain explicit unsupported constructs. Geometry is retained outside execution semantics.

Cycles are permitted: finite reachable markings do not imply finite trace language. Prove the reachable marking graph exhaustively using wide integers before calling the upstream u8 aligner. Reject invalid/duplicate references or weights; require a single final marking, finite exact graph within agreed budgets, all counts ≤255, reachable final and a path to final from every reachable marking. A silent cycle with an exit is allowed; a nonfinal closed strongly connected region with no path to final is refused. This promises the option to complete, not that every possible execution terminates. A budget breach is `inconclusive`, never a score or a soundness proof. Normative prospective limits: 128 generated nodes, 256 arcs, 10,000 reachable markings, 100,000 states per fitness/prefix search, 10,000 markings per tau closure, 10,000 equivalence subset pairs, 32 variants, 64 traces, 500 events and 64 events/trace. Every search-cap breach is inconclusive, with no partial scalar. Larger editor models receive a named resource refusal; this is not a claim of unrestricted Petri evaluation.

Independently convert the same frozen BPMN with pinned unchanged PM4Py, reduction disabled, labels preserved. Its converter has a different silent-node representation. Graph counts are not equivalence. For admitted finite marking graphs, compare the complete accepting observable automata using tau closure and on-demand subset-pair traversal (including final acceptance); cap the equivalence search explicitly and return inconclusive on exhaustion. This checks infinite cyclic languages through finite marking states, rather than enumerating a finite list of traces. Also retain the full BPMN→flow place/transition map, exact PNML, markings and all per-case behavioural assertions. Product and reference metric computations must subsequently use the **same hashed net**; different silent encodings can change precision and simplicity.

PM4Py's actual converter covers the five relevant node classes, supports optional reduction and can return node/flow maps. Its treatment of ordinary-node branching is why the proposed admission requires explicit gateways. [Primary converter source](https://raw.githubusercontent.com/process-intelligence-solutions/pm4py/release/pm4py/objects/conversion/bpmn/variants/to_petri_net.py).

## Fitness

Use unchanged `process_mining=0.6.2` optimal alignment on the admitted saved net: visible model move=1, log move=1, synchronous=0, tau=0. Preserve every alignment's moves, exact cost, states and errors. With shortest empty-trace cost `m`, trace length `n`, alignment cost `c`, frequency `f`:

`trace fitness = 1 − c/(n+m)`; `log fitness = 1 − Σ(f·c)/Σ(f·(n+m))`.

Report frequency-weighted average trace fitness and perfectly fitting trace fraction separately. For a nonempty evaluation log, an empty trace with n+m=0 has trace fitness1 only if its actual empty alignment cost is0: the model genuinely accepts empty behaviour. A zero-trace evaluation log returns `no_data` for all log metrics. Any required search failure invalidates that aggregate. Independent unchanged PM4Py alignments require explicit identical cost dictionaries, including tau=0; defaults are not equivalent. Compare exact optimal visible-deviation costs and weighted rational results, floats within absolute `1e−12` for hand arithmetic and `1e−9` across tools. Different optimal paths can be accepted if costs and full executable replay agree.

## Precision: a named weighted prefix metric

Proposed name: **PM4Py-compatible minimal-tau Align-ET prefix precision, fitting-log policy**. It is one specified precision measure, not a universal measure of behavioural excess. The literature documents limitations of existing precision measures. [Author-hosted research paper](https://www.vdaalst.com/publications/p926.pdf).

For each distinct nonempty **proper** prefix `p`, collect the set `L(p)` of observed next labels and its occurrence weight `w(p)`, including variant frequencies. Completed traces do not add an end marker or a terminal-prefix observation. Separately include empty prefix, weighted by number of traces, with observed start labels. Tuple keys preserve arbitrary labels; the reference must use an injective delimiter-safe encoding if its pinned version joins prefix strings. [PM4Py prefix extraction](https://raw.githubusercontent.com/process-intelligence-solutions/pm4py/release/pm4py/algo/evaluation/precision/utils.py).

Find **all minimum-tau-cost** prefix stop markings: synchronous matching moves cost0 and silent moves cost1; visible model moves and log moves are forbidden. This differs deliberately from fitness tau=0 and from unioning every exact replay marking. From these stop markings, take full tau closure and union the visible enabled **labels**, collapsing duplicate transitions with the same label. Call this set `A(p)`; escaping labels are `A(p) \ L(p)`. Then `precision = 1 − Σw(p)|A(p)\L(p)| / Σw(p)|A(p)|`. Empty-prefix enabled labels use initial tau closure. An empty log returns `no_data`. A fitting nonempty log with no activated visible labels returns `not_applicable_no_activated_labels`, with no scalar1. [PM4Py precision implementation](https://raw.githubusercontent.com/process-intelligence-solutions/pm4py/release/pm4py/algo/evaluation/precision/variants/align_etconformance.py).

The primary score requires every full trace to have zero visible-deviation alignment cost. For noisy/unfit logs, fitness still reports all traces, but precision returns `requires_fitting_log` with nonfitting frequencies. An optional fitting-subset diagnostic must name the selected subset and coverage; it cannot masquerade as whole-log precision. PM4Py's default skipping of unfit prefixes must not silently inflate a product score. Preserve all prefix keys, weights, minimal tau costs, stop markings, closure-enabled labels, escaping labels and integer numerator/denominator. Bound each search and tau closure; error or cap gives inconclusive.

PM4Py uses tau cost1 in its standard prefix-search cost construction; its default visible-deviation scale is 10000. Both must be read from the pinned artifact before execution. [Primary cost/closure source](https://raw.githubusercontent.com/process-intelligence-solutions/pm4py/release/pm4py/objects/petri_net/utils/align_utils.py).

## Simplicity

Name the metric **inverse mean arc degree, k=2**, on the exact unreduced hashed evaluation Petri net. Let `V=P+T`, `E=number of arcs`, and `d=2E/V`; score is `1/(1+max(d−2,0))`. For the admitted ordinary nets, arcs have unit weight and unique endpoints. Report P,T,E,d,k and the rational score. This is a structural metric: it is sensitive to conversion/hidden-node representation and may give different complex nets the same score1. It is not semantic minimality or proof of model quality. The published implementation itself notes a provenance TODO; do not claim a stronger theoretical justification. [PM4Py simplicity source](https://raw.githubusercontent.com/process-intelligence-solutions/pm4py/release/pm4py/algo/evaluation/simplicity/variants/arc_degree.py).

## Manual gate and corpus to freeze before execution

These are proposed hypotheses for independent QA arithmetic and semantics review, **not results**. Concrete BPMN XML, full symbolic Petri references, training/held-out variants/frequencies and individually named family subcases are now frozen in [the prospective fixture manifest](../fixtures/quality/corpus.json). Its input bytes and hypotheses must be reviewed before any bridge or evaluator run. Reference-net expectations and encoding-sensitive bridge expectations are explicitly separated.

| Case | Model and evaluation traces | Required independent hypothesis |
|---|---|---|
| Q01 | Linear ABC; ABC×3 | Fitness1, precision1; compact reference P4/T3/E6 gives simplicity1 |
| Q02 | A(B\|C)D; ABD×3 | Fitness1; activated weight12, escaping3, precision3/4 |
| Q03 | Same model; ABD×3, ACD×1 | Fitness1, precision1 |
| Q04 | A(B∥C)D; ABCD×2 | Fitness1; activated10, escaping2, precision4/5 |
| Q05 | Same model; ABCD, ACBD | Fitness1, precision1 |
| Q06 | A B* C; ABC, ABBC | Infinite trace language, finite markings; activated12, escaping3, precision3/4 |
| Q07 | Same loop; AC | Fitness1, precision2/3 |
| Q08 | XOR words AXD, AYD, BD; AXD×3, BD | Activated18, escaping3, precision5/6; changing counts to1 each gives7/8 |
| Q09 | Two same-label A transitions directly enabled, followed respectively by B/C; AB | All equal-tau prefix states required; precision2/3 |
| Q10 | Same labels, but tau before only C-route A; AB | Minimum-tau rule yields precision1; union-all-exact-prefix rule would yield2/3 |
| Q11 | A then optional B; A | Proper-prefix/no-end-marker policy yields precision1; publish this limitation |
| Q12 | Three alternative one-transition words A/B/C sharing source/sink; A | Fitness1, precision1/3; **compact manual Petri** P2/T3/E6 gives simplicity5/7; the larger BPMN bridge has its own P/T/E and separately computed score |
| Q13 | Linear ABC; AXC, AC, ABC | Fitness costs2,1,0; whole-log precision requires_fitting_log; unknown X retained |
| Q14 | Unicode, XML-sensitive task labels and duplicate labels; renamed IDs/DI | Same observable metrics under bijective label renaming; DI/flow labels are inert |
| Q15 | Silent cycle, bounded visible loop, parallel/XOR mixed gateway | Closure terminates by visited markings; exact cyclic equivalence or explicit inconclusive |
| Q16 | Missing/extra final marking, deadlock/nonfinal closed region without path to final, growth above255, cap, conditions, task branching, blank task | Named refusals; no silent conversion or fabricated metric; silent cycles with an exit remain allowed under Q15 |

Training/held-out must be designated before mining. Fixed synthetic reference models are not mined from their held-out log; report full training and held-out groups separately. Q14–Q16 are families and require individual named concrete XML/net/input/expected-status subcases in the frozen fixture manifest before execution. No family label alone counts as coverage. If a selected miner is later evaluated, use its genuine output/provenance/parameters and preserve observed differences. These quality tests do not make Alpha into SplitMiner or accept the missing production discovery criterion.

## Independent reference and execution gate

### Actual wheel source inspected before implementation

Root fetched the exact 2.7.17 wheel above; Science read the five extracted files without importing the package. Their raw SHA256 pins are:

| Wheel member suffix | SHA256 |
|---|---|
| `algo/evaluation/precision/variants/align_etconformance.py` | `6C29314C049629A38B2BD969B3AE07AB83DC814C4185A56F507DD0B1D161A39E` |
| `algo/evaluation/precision/utils.py` | `62A2641B8F9ACE1B7E508CC97BDE4D8CAE5CF57CCB36F3B15F695C0CFBBED524` |
| `objects/petri_net/utils/align_utils.py` | `99207FDB93FC442E21761D9296B201D638D60C2BC22EA89D42C5D7FD68E064C2` |
| `algo/evaluation/simplicity/variants/arc_degree.py` | `84EDF8A85A7CB3E313056B58493B430B960FFC47CBB57EFE6559D924B36249F7` |
| `objects/conversion/bpmn/variants/to_petri_net.py` | `257441CA99BCEDE7D9EC356998A8E2B55A8274C8ECA52E381F42C471C19FFAD1` |

The actual wheel confirms proper-prefix occurrence counting, all minimum-tau prefix stop markings, label-set union, empty-prefix weighting, default tau1/visible10000, k2 simplicity and optional converter reduction. Its precision defaults to scalar1 for zero activated labels and silently excludes unfit prefixes; the wrapper must apply this contract's `no_data`, `not_applicable_no_activated_labels` and fitting-log policies explicitly, preserving the unchanged reference result separately. Runtime dependency availability and actual independent execution are still unverified. No execution credit follows from these source pins.

PM4Py 2.7.17 remains a prospective executable reference: static source inspection above is complete, but Science has not imported or executed its runtime. Official PyPI advertises wheel `pm4py-2.7.17-py3-none-any.whl`, 2,180,398 bytes, SHA256 `77fa0bbbe8284f0c94d577163213b5d4758bcf309a0266d34278a4476df28686`; source archive SHA256 `3188b876fec35f03615a6a2d94e7e5e199d6cf812eb9bacd91709cef1d9eab36`. Dependency closure and interpreter/module identities must be frozen and independently reviewed before import/execution. Dynamic `release` sources and the mismatched version title/path on the documentation are research evidence only, not artifact pins. [Official version metadata](https://pypi.org/pypi/pm4py/2.7.17/json).

Use the unchanged licensed package only in an isolated reference process, with actual distribution license retained. Its source headers and metadata identify AGPL; copying implementation code into the Rust product is outside this proposal. Independent source inspection of the exact wheel must confirm prefix/tau/default policies and fitness overrides. A package that imports but cannot execute the chosen APIs is not a working reference. Product output and reference input must share a full graph/label/marking bijection; return raw integer components and full diagnostics, not only rounded scalar matches.

Root controls dependency fetches, process Job, threads, deadlines, disk/memory budgets and builds. Existing browser/PG/CAS/restart requirements apply if runtime routes/UI/persistence change; this draft author does not own those files. Independent QA reviews corpus hypotheses before execution, all actual candidate outputs afterwards, and public artifact regeneration/tamper tests. Prior accepted receipts are carried by exact identity and affected regressions, not silently revoked.

## Estimate and stop conditions

Read-only research is complete; no model generation/evaluation occurred. A developer-only bridge+three-metric proof is an estimated 4–5 hours after contract agreement and available reference dependencies, plus 60–90 minutes independent QA/publication. Product integration adds substantial separate work; do not promise it from a working standalone example. First 30–45 minutes after GO must establish the exact PM4Py dependency closure and converter/evaluator source policies. Missing reference, semantic mismatch or exhaustion of that window triggers a factual blocker and revised prioritization, not a toy replacement evaluator. New native work freezes at 07:39:14 UTC; final sprint deadline09:09:14. R5 follows the explicit R4 result/decision, not an inferred full PASS.
