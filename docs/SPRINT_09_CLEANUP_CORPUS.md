# Future DISK01: frozen manual corpus and observable acceptance protocol

Design artifact only. Sprint08 Council decision is five FOR for exact proposal `67E5EB1C2853AFCDB65E2219745397CE2BCABD59959F29F0C6F46004A7814D52`, deferring destructive cleanup. This file authorizes no cleanup, restore, SQL execution, runtime change, or release. DISK01/R3-04 remains OPEN. The author is a developer, not the independent QA or TD accepting this work.

## Ownership and freeze

Root owns future scope approval, shared integration and artifact freeze. A cleanup developer implements only after separate authorization. Independent QA owns fixture construction, actual process/network fault evidence and raw execution records. TD independently reviews identity, hashing, transaction and recovery proofs. Customer validates usable recovery and truthful disk-space claims. Each future acceptance records the exact source, executable, package, PostgreSQL version, archive, plan, fixture and protocol SHA; a changed fixture or protocol requires a new named freeze.

Before implementation, QA must freeze the complete historical old-0.3 archive bytes, archive SHA/size, restore-helper version and an actual full inventory. The inventory includes every KV key/version/value digest, project ID/header, record composite key/version/value digest, marker field, ledger field and resource-sequence state. Counts are measured then: this document deliberately supplies no invented historical counts. No selected-project, reduced-log, sampled, or truncated fixture is eligible. Protected historical installations are never test targets; only new explicitly owned databases/clusters are used.

## Literal small fixture S and hash oracle

The following is a finite conceptual fixture, constructed by normal maintained migration/writes. It is not SQL or an executable script. UUIDs are illustrative stable fixture IDs, not production targets.

| Row | Literal defining content | Purpose |
| --- | --- | --- |
| legacy L1 | `repository/project-11111111111141118111111111111111`, positive version 7 | Eligible retained row |
| legacy L2 | `repository/project-22222222222242228222222222222222`, positive version 11 | Second eligible row, detects partial deletion |
| current H1/H2 | Corresponding project headers, normal current positive versions | Both current projects remain |
| records | Each project has one complete normal log and one model created through maintained fixtures | All actual record kinds and payloads frozen |
| generic G | `fixture/keep`, version 3, JSON `{"a":1,"b":[true,null,"é"]}` | Nonlegacy exact preservation |
| auth | Complete normal owner/editor/viewer accounts, memberships and sessions created through maintained fixture helpers | Full private state, never publicly printed |
| markers M1/M2 | Corresponding project ID, source version 7/11, exact Rust source hash, actual known schema-2 checksum | Eligibility bindings |
| ledger/sequence | Actual migration ledger and sequence state from fixture construction | Exact preservation, including is_called |

Payloads and valid auth hashes are generated with maintained constructors, then frozen as full private fixture bytes; the small table does not substitute for their exact bytes. Define `PRE` as the complete managed-state snapshot. Define `ELIGIBLE={L1,L2}`. Define `POST=PRE` with precisely those two KV rows absent; no other value or version differs. A legitimate current H1/model update after migration must be present in both PRE and its full backup while L1 stays unchanged. Expected cleanup remains eligible; current normalized state is never compared to the old repository payload as an equality prerequisite.

Eligibility oracle is exactly SHA256 of existing Rust `serde_json::to_vec::<Value>` bytes. Whole-state oracle is a separate deterministic length-framed, sorted inventory of complete canonical JSONB text digests on pinned PostgreSQL plus keys, versions and all scalar fields. Unit fixtures include reordered object input, Unicode, arrays and null; prove streaming Rust serialization equals the existing byte-vector serializer. Never label SQL JSONB text digest as source_sha. Independent QA compares complete values on source and fresh restore before trusting digest inventories.

## Finite mutation matrix

Each case starts from a separately identified fresh S or full historical fixture. Mutations below describe future fixture changes, not actions performed for this document. Refusal means no source row/value/version/sequence changes; retain raw actual error and complete before/after fingerprints.

| ID | One frozen mutation or condition | Expected outcome |
| --- | --- | --- |
| C01 | S, exact full archive -> NEW restore, equal PRE, both offline | Apply removes L1+L2 atomically; source equals POST, restore equals PRE |
| C02 | Legitimate normalized update already included in PRE/archive; legacy unchanged | Same C01 success |
| C03 | Same source database via a different URL/hostname alias | Refuse equal actual identity |
| C04 | Distinct database OIDs in same actual cluster, equal managed PRE | Identity test may pass; all remaining gates required |
| C05 | Physically copied cluster with equal system_identifier and database OID, or identity privilege unavailable | Conservative refusal, no URL fallback/grants |
| C06 | Archive byte changed; manifest SHA/size wrong; another archive substituted | Refuse before source mutation; failed new restore retained if already created |
| C07 | Source G value changes to `{"a":2,"b":[true,null,"é"]}` without version change | Refuse stale full-state proof |
| C08 | Restore G same-version change, or legitimate login adds a restore session | Refuse source/restore inequality |
| C09 | L1 version 8 with M1 source_version still 7 | Refuse entire batch; L2 retained |
| C10 | L1 JSON changed at version 7; marker hash unchanged | Refuse exact Rust binding |
| C11 | M1 source_sha/checksum changed; unknown legacy key; current H1 missing | Each independently frozen subcase refuses entire batch |
| C12 | Ledger 1, malformed stage, unknown future schema, unsupported managed-table trigger/RLS | Each independent subcase refuses |
| C13 | Source lease busy; restore lease busy; pre-existing writer; table lock contention | Each independent subcase controlled refusal |
| C14 | Valid ready schema with L1/L2 already absent and markers preserved | Explicit empty success, zero database writes |
| C15 | Stale plan SHA; supplied confirmation SHA wrong; plan identity changed | Refuse before DELETE |
| C16 | More than 10,000 managed rows, key >512 UTF-8 bytes, plan >4 MiB | Each boundary refusal; exact-at-limit case independently measured |
| C17 | Any SQL exceeds 5s, lock exceeds 2s, final transaction exceeds 10s | Controlled failure/rollback; no increased budgets |
| C18 | C01 completed, restore full original archive into another NEW database | Complete PRE recovered; current compatible startup/export/RBAC pass |

Run the full unreduced historical fixture through C01/C02/C18 and full restart/export checks. Small S gives precise mutation oracles, not historical scale or recovery credit. Do not claim immediate physical file shrink after DELETE; measure logical removed rows/bytes and separately disclose PostgreSQL space reuse.

## Observable phase protocol and honest fault gates

Record actual native PID/creation time/executable hash, actual backend PID, both live identity pairs `(system_identifier, database_oid)`, leases and transaction phase timestamps. A proxy or independent observer must preserve private authentication and capture safe protocol/phase metadata only. Launch/stop only owned children, with path/PID/creation guards. Do not add a production sleep, fault flag, weakened lock, disabled timeout, or security bypass merely to expose a boundary.

F01 — before DELETE: independently establish live transaction/locks before any DELETE, interrupt the owned native process/backend, then read complete source state through a new connection. Expected PRE, not a count-only check. This is future NOT-IN-RUN until actual evidence exists.

F02 — after DELETE, before COMMIT: the strongest feasible future method is an independently reviewed test-only PostgreSQL protocol proxy that forwards the production DELETE and its real success response, then intercepts the client's next COMMIT request before forwarding it. The observer records returned exact keys/versions and never forwards COMMIT, then terminates the owned connection/process. Ordinary second-session reads cannot see uncommitted deleted rows and are insufficient evidence. This proxy does not change the executable, source locks or timeouts. It must account for PostgreSQL SSL negotiation/authentication and extended-query framing; an unverified proxy, log line emitted before execution, unit rollback, or process kill of unknown phase receives no F02 credit. Preserve normal deadlines; a proxy stall that merely times out proves timeout rollback only. Expected complete PRE after backend disconnect. **F02 is NOT-IN-RUN and feasibility unresolved now.**

F03 — uncertain acknowledgement: a separately reviewed proxy forwards the real COMMIT, observes PostgreSQL's successful commit response, then drops that response before the client receives it. Expected server POST, client explicit `cleanup_outcome_unconfirmed`, and read-only full reconciliation to POST. Record actual server response separately from client error. A kill after a logged success is not an uncertain-ACK test. **F03 is NOT-IN-RUN and feasibility unresolved now.**

If the production CLI batches DELETE and COMMIT in an inseparable protocol message, or the observer cannot prove exact boundary without changing production semantics, F02 remains NOT-IN-RUN. If the proxy cannot distinguish completed commit from a forwarded request, F03 remains NOT-IN-RUN. Do not infer either result from general PostgreSQL transaction guarantees. An ordinary backend abort test may supplement these gates but cannot replace actual CLI boundary evidence.

For uncertain outcome, obtain a new read-only complete snapshot and classify exactly PRE, POST, or unexpected state. PRE permits a new separately authorized operation; POST permits an explicit reconciled success receipt; unexpected state is STOP. Never retry blindly. Receipt-write failure after a known commit is a separate result, not rollback proof. Keep the original verified restore unchanged throughout.

## Final gates

G0 resolve prior restored-project STOP with independent full evidence. G1 obtain future exact-scope Council approval and freeze actual complete fixtures/inventory. G2 independent identity/hash/schema/lease review. G3 actual C01–C18, F01–F03 and full historical/recovery results, including all failed attempts and full private stdout/stderr/exit evidence. G4 exact immutable packaged candidate and independently reviewed rollback instructions. Any unresolved F02/F03, incomplete historical corpus, budget failure, or source/restore inequality leaves DISK01 OPEN. No test or vote has been executed by writing this document.
