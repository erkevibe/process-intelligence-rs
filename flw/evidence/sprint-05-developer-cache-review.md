# Sprint05 developer cache review — draft, nonvoting

Recorded 2026-10-10 22:49:31 UTC.

Scope: source review by the production author of `src/repository_v2.rs` and `src/resource_cache.rs`, plus targeted read-only inspection of the Root-owned get/commit and normalized SQL integration. This is a developer self-review, **not independent QA, a Council vote, frozen-candidate acceptance, or live single-flight credit**. No production edits, database connection, process action, build or test execution were performed for this note. Root reports integrated ordinary69 PASS/13 ignored and clippy02 PASS; this note does not independently re-audit those raw logs.

Reviewed owned-file identities:

- repository_v2.rs SHA256 `1A1E7F873AAD6C970F241D2BE182FA37D8E02920B5622063C6FB95305D5A8669`.
- resource_cache.rs SHA256 `E150ADB9310874C2CA0832373FC618E042AD608DC51210B1C194AB6B4228B66E`.

## Source conclusions

Baseline contains weak EventLog/Analysis/model identities and a log_state Value only. That Value excludes data/source/analysis; weak control blocks cannot retain their nested vectors/strings after the last strong owner drops. Cache flight results hold weak original payloads plus a metadata template whose heavy fields are replaced with empty payloads. The registry itself holds weak flight locks, prunes inactive entries, and has a 64-key admission ceiling. Neither mechanism is a hidden strong owner of the original heavy payload corpus. Clean retained cache entries intentionally hold strong resources under the separately charged 128 MiB/eight-entry limit. Active callers, dirty transient maps, validation buffers and complete backup remain separate owners.

Catalog construction unions authoritative IDs with transient resident maps, then applies explicit deleted-ID sets. Absence from a resident map cannot emit DELETE. A log explicitly removed emits four component deletions; a model emits one. Existing pure tests cover unloaded sibling catalog preservation and four-component explicit deletion, plus weak-baseline owner release. `mark_persisted` clears lazy resident maps only after the Root commit path obtains successful SQL acknowledgement; a failed SQL/CAS path does not call invalidation or mark_persisted. SQL checks the project revision before resource writes/deletes and commits the batch plus record-index check in one transaction. Independent actual stale-CAS/partial-batch and full sibling version/value preservation remain required.

Cache hits validate the current stored version tuple; loading uses the four-component snapshot API and rechecks versions before publication. Root source checks the current actor before requesting a base resource and applies user views afterwards. Strict lazy validation reconstructs filtering and analysis before publishing a loaded log. Global cache mutex sections clone resource Arcs only; removed entry owners are declared before the guard so payload destruction follows guard release. SQL, deserialization and charge traversal run outside that global mutex.

## Ignored PostgreSQL single-flight test assessment

`postgres_oversize_concurrent_singleflight_uses_one_actual_load` is test-only and guards an explicitly supplied pi_s5_* database before connecting. It holds the existing per-key flight lock, starts two real cache calls, and waits at most five seconds for two misses after their real SQL version reads. Releasing this finite scheduling gate exercises the production flight mechanism without adding runtime delays or fault flags. Each returned log remains owned by its JoinHandle or parent local, so the first loaded payload is available to the concurrent waiter's weak-result upgrade. The assertions require one actual load, one flight hit, one oversize bypass, zero retained entries/bytes, matching data/source/analysis Arc identities, matching full streaming SHA256, and unchanged project revision/component versions.

This is a credible source design for the missing concurrent oversize test, but it has only compiled as an ignored test according to Root. **Actual frozen-source execution by independent QA is outstanding.** The two equal returned SHA values establish agreement between readers, not an independent comparison with the pre-existing corpus oracle; QA must retain its separate full-value/corpus comparison. Revision checks demonstrate no managed versioned change; the test does not claim an exhaustive database-wide DML audit against arbitrary unversioned administrator SQL. The selected log must actually exceed the retained charge budget; the bypass assertion enforces that assumption during execution.

## Open acceptance gaps

Repeated BODY observation active1 versus two paused responses remains an acceptance STOP. This source review does not attribute it to TCP buffering or close it, and does not transfer ordinary-test success into real HTTP/body-permit credit. Root-owned body completion/drop/disconnect and immediate third-operation refusal need an independently reproducible exact-candidate witness.

Single-flight SQL execution, cross-project progress, requested-corruption refusal, role changes on hits, eviction/full export hashes, CAS and sibling writes, crash recovery and fixed performance gates still require independent exact-candidate evidence. Project mutex serialization can make two HTTP requests nonoverlapping, so flight_hits0 in that scenario provides no concurrent-flight proof. Cached byte charge is an ownership estimate, not an RSS ceiling; the source review cannot close the fixed working-set gate or claim enterprise memory scalability.
