# Independent business QA draft04 observation

Owner: `/root/qa_business_s9`, independent from runtime author, coordinated by `/root/qa_process`. Exact draft executable SHA256 `EE74E4F9F7DE56728E4380857BE78FD8CF4F2CA1F9955825E2BCFC6DD0498483`. New owned PostgreSQL database and HTTP3073 only. Protected installations received no login, SQL, stop or configuration changes. Execution began after primary QA released its full cleanup quiet window at10:07:19 UTC.

This is a partial draft observation, not criterion PASS, final-candidate acceptance or a Council vote. Private complete values, credentials, sessions and responses remain in protected `.local/sprint09/qa/business01`.

## Confirmed defect

An ordinary authenticated writer can upload a modified project backup with a recomputed plain payload digest and syntactically supported business policy. Restore accepted a client-provided actor, time, project/resource IDs, revision, policy parameter hash and `committed` outcome. The created project's audit export exposed that fabricated successful event. Actual input SHA256 `f658e300112c81a0037a2a686f398e2d087764ca7a62b027c4da489350183b7c`, restore200, project open303, export200. This differs from a database administrator editing the database. Root and primary QA received the actual counterexample. An earlier unsupported-rule input refused422 with complete state unchanged; both attempts are preserved.

## Executed draft scenarios

- Empty workspace setup saves the real bootstrap event; independently recomputed exact parameter digest matches. Repeated setup refuses with complete managed values unchanged.
- Account/default-project creation, project creation and grants; owner/editor/viewer mutation guards and strict unknown-field refusal. Two concurrent project revision attempts yield exactly one successful commit.
- Folder create, rename, move and delete; cycles, parent-with-child deletion and stale revision refuse with complete values and audit unchanged.
- Strict XES, CSV preview/import with mapping and delimiter, filter, calendar, personal view, discovered model and BPMN import produce versioned committed events. Threshold0 refuses; threshold1 succeeds. Further producers and full action-specific digest assertions remain pending.
- Archive sessions leave target; active-target delete preview and wrong typed ID, phrase, digest, revision or unknown field refuse with complete state unchanged.
- A confirmed permanent deletion removes exactly the target auth project, normalized header and records. Other projects, users, already-rebound sessions, generic KV, records, ledger and resource sequence remain equal. Minimal former-owner witness survives; repeat refuses; editor/viewer exports do not reveal that owner's witness. This target had no migration marker or retained legacy key, so those deletion subcases remain pending.
- Real512 then513 auth, project and former-owner witness events retain exactly512 complete ordered entries; exports show matching totals/dropped. Witness retention used real project creation, archive and exact confirmed deletion, not injected journal rows. The actual loop made3585 requests during10:12:44.334–10:14:30.183 UTC; this is not a performance benchmark.
- Current-owner archive with only Viewer alternatives refuses with the complete managed state and audit unchanged. With a lexically earlier Viewer and later writable Owner alternative, both initiating-owner sessions choose the writable alternative. Editor alternative also permits recovery; other affected Viewer changes no role. Noncurrent archive and subsequent restore/create succeed.

## Remaining gates

Exact final candidate repetition; all maintained producers and validated parameter bindings; independent-owner retention isolation; legacy/unsupported/tamper/downgrade cases; revoked-current-role and remaining stale/CAS cases; nonterminal and captured worker/session/cache/pending-preview cases; target retained legacy and marker deletion; actual atomic write/protocol faults; restart plus complete stock backup/new verification restore and separate application recovery. No ordinary HTTP error is treated as a rollback or unknown acknowledgement proof.

Harness-only failures are preserved: the first snapshot had a wrong relative cwd before SQL; the first deletion verifier encountered a null empty marker array after acknowledged delete and was corrected to read existing complete PRE/POST without repeating mutation. These are not silently relabeled runtime failures or discarded.
