# Prospective diagnostic canonical schema-hint projection

Draft for actual Root, Science, QA, TD, PM and Customer agreement before implementation. This is a separate narrow addition to the approved diagnostic BPMNLabel policy; it does not amend the quality formulas, original R4 criteria, product parser or standard-loop refusal.

All seven immutable SplitMiner exports contain a root attribute in the XML Schema Instance namespace. The current strict product XML reader rejects prefixed non-namespace attributes, so DI-label-only projection cannot admit those exports. Preserve that observation rather than calling it a failed miner or silently removing arbitrary attributes.

## Exact permitted metadata

Only an attribute with expanded name {http://www.w3.org/2001/XMLSchema-instance}schemaLocation, directly on the root {http://www.omg.org/spec/BPMN/20100524/MODEL}definitions, is eligible.

Its raw quoted value must be exactly the ASCII/UTF-8 text:

    http://www.omg.org/spec/BPMN/20100524/MODEL BPMN20.xsd

These are exactly two case-sensitive tokens separated by one ASCII space. Do not accept another namespace, remote schema URL, path, additional/missing token, entity reference, leading/trailing or alternative internal whitespace. A namespace alias other than xsi is allowed when it resolves to the exact XSI URI. Single or double attribute quotes and legal whitespace around the equals sign are allowed; they are retained in the recorded lexical span. No unbound or wrong namespace prefix qualifies.

At most one such expanded-name attribute is allowed. Duplicate same-QName attributes and duplicate expanded names through different aliases are invalid XML and must be refused. Other root XSI attributes, including type/noNamespaceSchemaLocation, remain unsupported. An otherwise matching schemaLocation on a process, task, DI element or non-root definitions is refused, not projected. No other schema or behavior attribute may be removed.

Never open, resolve, fetch, validate against or follow BPMN20.xsd or any schema hint. Use a namespace-aware, DTD/external-entity-refusing reader and the existing byte/depth/element/encoding guards. Raw standardLoop and other unsupported behavioral constructs retain their independent preflight/refusal policy before either converter.

## Exact byte operation and provenance

Record the original XML byte length and SHA, root association, expanded attribute name, exact qualified spelling, quote style, raw quoted lexical bytes and byte span/hash. The removal span begins with the first byte of the attribute QName and ends immediately after its closing quote. It includes internal whitespace around the equals sign but does not consume surrounding separator whitespace or namespace declarations.

Validate the entire input before constructing or writing projected bytes. Remove only that recorded attribute span. Preserve every other original source byte and assign the result a different hash; a no-hint input is an explicit unchanged/no-op. Keep the original XML and exact removed bytes in evidence. A refusal is atomic: no projected replacement or scalar.

The schema-hint projection and separately approved DI-label projection are independently named stages with exact intermediate hashes/spans. Composition must map spans to their stated input bytes, verify original-minus-recorded-spans exactly, and preserve all behavior node/flow attributes/labels/children. Removing this attribute alone does not establish strict admission when BPMNLabel or another unsupported construct remains.

Reparse the final diagnostic projection using the unchanged strict product parser. Product-import compatibility of the original, diagnostic projection admission and unchanged reference compatibility remain distinct. PM4Py receives the original positive raw XML; its graph equivalence must be proved independently, not inferred from a successful metadata projection.

## Frozen prospective gate

Freeze fixtures/quality-schema-hint before implementation: root canonical double quotes; equivalent alias/single quotes; whitespace around the equals sign; no-hint no-op; a byte-identical real miner original whose attribute-only projection still retains DI. Include explicit negative files for wrong namespace/root/placement, noncanonical values/whitespace/entities, duplicate attributes/aliases, other XSI attributes, DTD and raw standardLoop.

Positive hypotheses include exact removed lexical byte spans and hashes, exact projected document hashes and unchanged semantic maps. StandardLoop stays a behavior refusal; no diagnostic schema metadata approval can erase it. The existing DI25 fixture corpus/source and base quality corpus/method remain unchanged. No numeric quality target is invented.

Independent QA validates concrete fixtures before implementation. Later, verify exact removal/reconstruction, unchanged full behavior maps, original versus final-projected accepting observable automata, no external schema/DTD access and atomic refusals. All eight historical miner outcomes stay visible, with original failures and warnings. This scope agreement is not acceptance or whole-R4 closure.
