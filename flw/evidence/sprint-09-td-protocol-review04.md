# Independent TD protocol observer04 review

Source-only disposition: conditional GO for the literal small simple-Query feasibility experiment; no candidate or cleanup acceptance.

Fully read and independently hashed before experiment:
- observer04: 74A5F02675052857CADD4C751E6FB54DC47FBA8E8AB893204184FC65F3020D4F
- fixture01: 9C44A1C1660B209F7DC23201BBB8586D88EDF8048FFA944C20AD551792DA9033
- client01: 5B5728B761777F15E7B1DB6891154CA1E8CC5F1C3C9AEDB268C7F9E910430349
- contract01: CC18A7905E41005A4643D629008BEDF6F6740AE602E8BBCE35BC622F3F45FCD0

Scope: NEW owned PostgreSQL 5450 and observer15450 only; literal BEGIN, local5/2/10second budgets, acknowledged LOCK TABLE, one DELETE RETURNING L1/version7 and L2/version11, postselect, separate COMMIT. Observe/F01/F02/F03 require full independent PRE/POST and native client exits. F01 must have actual acknowledged lock before DELETE interception. F02 must associate exact returned rows and DELETE completion before withholding COMMIT. F03 must receive successful real COMMIT completion before withholding its response. Refusal or missing phase is not PASS. No experiments were executed by TD; no actual result is asserted here.

Cause-specific improvements: optional single semicolon with multi-SQL refusal, immediate server ErrorResponse refusal, pending execution association, exact typed RowDescription and RETURNING rows/count, no partial portal execution/pipeline, transaction and lock confirmation before DELETE arm. These address earlier source-review deficiencies for this narrow simple-Query client.

S9-TD-PROTO-EXT01 remains open for actual Rust extended framing: source front() does not bind Describe responses to statements; backend T is stored only while pending DELETE. A statement Describe RowDescription before Execute is ignored; extended Execute need not emit another T. Bind result formats are not parsed. Binary result formats cannot be inferred from an earlier statement descriptor. The proxy may safely refuse such a client, but the small simple-Query result must not be transferred to actual Rust cleanup fault evidence. Owner QA; closure: reviewed compatible mechanism plus exact actual-client protocol evidence before candidate fault.

No protected resources, production files, security settings or database budgets were changed. Original observer01–03 and contract wording remain historical. The contract pending note is not relabeled completed by this source review. No new skill is warranted before verified actual solution.
