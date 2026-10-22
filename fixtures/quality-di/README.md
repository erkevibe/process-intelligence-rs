# Prospective diagnostic DI fixtures

These are frozen inputs and precomputed hypotheses for R4_DIAGNOSTIC_DI_ADDENDUM.md, not implementation or successful execution evidence. The approved fixtures/quality corpus is unchanged.

corpus.json defines five positive and twenty negative cases. Positive originals contain explicitly authored literal BPMNDI label subtrees; their exact UTF-8 spans, raw bytes, hashes, direct parents and expected projected document hashes were computed during fixture construction. No projector, BPMN semantic parser, metric engine or reference conversion generated these expectations.

The expected projected XML retains the original shape bounds and edge waypoints. It is byte-identical to the corresponding annotation-free document. Both the linear process and the cyclic A B* C process have explicit node/flow maps. The eventual proof must compare complete accepting observable automata, including the cyclic language; checking several trace samples is insufficient.

Negatives independently cover behavior hidden inside a label, foreign namespaces, invalid geometry, unknown attributes, nested/multiple bounds, invalid parents, DTD and standardLoopCharacteristics. A negative is atomic: no partial projection, repaired model or quality scalar. The DTD external identifier must never be opened. Standard-loop behavior must be refused before either converter; it is not an annotation.

The original XML and recorded annotation bytes must remain available. The diagnostic projection gets its own hash and is never reported as successful product import of the original. The real PM4Py converter receives the original positive input. Implementation and native execution require the separate prospective role agreement and independent fixture review.
