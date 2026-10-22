# Prospective diagnostic BPMNLabel DI projection

Draft, before cohort-specific implementation/execution. This supplements the
exact R4 method `8E17394B9E1E79FFD0BCDA4B2A55D0454FEFF5B3C017B91AB8E115D11F9F974D`
and the complete [genuine-miner cohort](R4_MINER_COHORT_DRAFT.md).
It does not change product import, model storage, metric formulas or thresholds.

The immutable SplitMiner exports contain BPMNLabel diagram annotations. The
existing strict product parser refuses that DI child. For the diagnostic only,
allow a separately reported execution-inert projection, preserving all original
XML bytes and hashes. The reference still receives the original XML, not a
repaired miner model. Product compatibility, diagnostic admission and reference
compatibility remain separate flags.

## Exact permitted operation

- Use a namespace-aware, DTD-refusing XML reader; retain the normal input byte,
  namespace, reference, label, coordinate and resource guards.
- Only a `BPMNLabel` in the BPMNDI namespace, directly within `BPMNShape` or
  `BPMNEdge` in that same namespace, is an eligible annotation. Record its exact
  source span/hash, parent association and raw subtree bytes. Retain the original
  document and expose the projected document with a **different** hash.
- Within the eligible annotation permit namespace declarations, an optional id,
  and at most one DC `Bounds` with finite x/y/width/height within the documented
  geometry limits (nonnegative label width/height). Refuse unknown children,
  behavior-namespace elements, extensions or attributes. Never discard arbitrary
  subtrees on the basis of their unqualified names.
- Remove only these recorded DI-label spans from the diagnostic semantic parser's
  input. Preserve every other source byte, including task labels, flow labels,
  gateways, node/edge identities, source/target references and behavior children.
  Reparse through the unchanged strict product parser. The parser's success on
  this projection must not be called a successful product import of the original.
- `standardLoopCharacteristics`, conditions/default flows and every other
  unsupported semantic construct remain refusals. In particular, preflight both
  evaluators against standardLoop before PM4Py can silently ignore it. No ordinary
  task replacement, changed loop flag or fabricated scalar is allowed.

## Prospective tests and evidence

Before execution freeze positive annotation-bearing copies of a known model and
negative fixtures with a BPMN task/condition or unknown namespace inside a label,
wrong label namespace, invalid bounds and bad parent. The original and projected
semantic node/flow maps must match exactly; only the recorded DI spans differ.
The original model, an annotation-free equivalent and an independent PM4Py
conversion must have equal complete observable accepting automata, including
cyclic languages where applicable. Geometry and original raw spans remain in
the evidence independently of conformance.

All eight historical miner outcomes stay in the new cohort matrix. No hidden
selection follows from admission. Original training groups remain training;
source-aware carry is distinguished from a new miner execution. Supporting a
standardLoop requires its own genuine semantic/reference extension; this
annotation proposal does not authorize that extension or whole-R4 acceptance.

The Source/Root/QA/TD/PM/Customer prospective agreement and independent concrete
fixture review precede cohort-specific implementation and measurement. Existing
private resource budgets, native supervision and sprint deadline apply.
