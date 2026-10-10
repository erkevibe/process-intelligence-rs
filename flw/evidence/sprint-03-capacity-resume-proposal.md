# S3-RESUME-3: capacity and metadata reserve repair

Immutable targeted proposal; fixed five seats and invitation are in sprint-03-capacity-council-invitation.md. This decision resumes affected acceptance work; it does not accept a release.

## Observed failure and repaired path

Exact candidate89cdcbcef5c988ff46716bb0e1ae16e8c2334e6a / EXE B6D116F87AC00896CCD1F78024FAE061EE7552F34BB2EC2CFC71D3525D8E6FBE was rejected after a real accepted100000-event import exceeded PostgreSQL's268435455-byte JSONB container limit. Existing data were preserved; the worker failed closed. Candidate89 and its package remain historical rejected artifacts.

Root's repair rejects oversized documents BEFORE queue/SQL and validates the whole batch before any write. Conservative structural bounds include UTF8 keys/strings, container headers/JEntries/alignment and default finite serdeJSON numbers. Actual locked feature audit has no arbitrary_precision. New repository payload mutations and new job admission use266272768-byte budget; already-admitted progress/terminal and startup recovery use268369920. The2MiB difference protects bounded job metadata. Capacity is a controlled project_capacity error, not storage_unavailable, and cannot poison the worker. New results never replace the old repository on refusal; accepted background jobs persist Failed/null before publication. HTTP synchronous/admission capacity errors use413. User wording and docs explain that eight logs are a count ceiling and may not all fit.

Exact repaired draft release EXE SHA256: 0BFBF697B3A29AE1357FF13EAD049F0E3C2BB70F3EE40C65CE4F356D9A0B9D77. This is a root working-tree diagnostic build, not a frozen source89 build. Raw source hashes:

- src/storage.rs:923C7A0EFE051CA0FADBA345E42C47E58D5BF2AA21E5FCB0F1F39C4B9ED6E0CD
- src/web.rs:33706EE6F9A596D59C4C28FBB27D4C184E7914EACBCBE760CE2EFB7F575FD843
- src/platform.rs:D8B2288D31B50F4792C5DB8F22850C4897E494E4C2C9DA4D94F77777EFEF8418

## Actual independent evidence

QA exact-cap03 capacity-regression05 exit0 /4PASS, report SHA256 DD34A7996157D6E9EDCCF9280A9E200CFEDD9D2249AD09C9CFAE2FAC44D83150: SAME cumulative project and SAME100000-event input, controlled durable Failed/project_capacity/null; six original complete log hashes preserved; prior export and health200; post-refusal model write; accepted cancellation and terminal revisions survive actual restart idempotently. No project/payload reduction or reset. Earlier cap02 actually recovered the two nonterminal jobs from the rejected candidate and preserved the same logs. Two verifier-only404 route mistakes were retained; corrected05 uses a preflighted literal registered route. Those failed helper attempts are not relabeled fullPASS.

QA independent realPG capacity_batch_refusal_is_atomic_and_does_not_poison_worker exit0 /1PASS: first small and second oversized documents both absent after pre-SQL refusal; same worker health and subsequent small write/read revision1 succeed. This test is explicitly ignored without isolated pi_s3_fresh configuration; it is not counted as an ordinary test PASS. Root's three structural-bound unit tests, ordinary suite and clippy passed separately; final frozen suite must rerun.

QA's own safe targeted summary SHA256 EFE1BD93A21B052A505EA2D22246631D307437209D6D4CB9DE02CEB3E82A664F confirms exact100000 events /17200026 input bytes. A deliberately exhausted-reserve/concurrent-expansion experiment was not executed; reserve sufficiency is the bounded runtime-source argument plus the actual ordinary cancel/restart regression, not a claimed hostile-load certification.

TechnicalDebt independently read exact report05, exact source and actual batch result; scoped CAP01/CAP02 cause is closed. QA's actual independent conclusion and each vote must be recorded separately before resuming. No author-only closure.

## Proposed decision and limits

Resume the affected Sprint03 acceptance/delivery preparation after actual QA and TD closure plus more than half of five real votes FOR. Root may commit/freeze the corrected source, build fresh EXE/ZIP, run exact integrated/nativePS5/provenance/PG/oracle/BPMN/recovery checks, and update the draft PR/CI. Preserve all historical rejected artifacts, logs and existing user installations. Packaging may move the rejected private candidate directory/ZIP into a checked private quarantine, retaining identical hashes, to create a fresh canonical candidate. No rejected artifact may be published as accepted.

Final release still requires independent exact corrected artifact acceptance and a separate final Council proposal/vote. Normal jobs can use a fresh separate project while the original cumulative corpus remains unchanged for mandatory capacity regression; this is a declared project-capacity boundary, not a smaller input workaround.

S3-TD-SCALE01 stays HIGH/OPEN: whole-document writes/clones and startup typed roundtrip inside a short SQL transaction, aggregate capacity/RSS and worst-case64projects are not certified. Separating logs/models into records and bounded validation is next-sprint priority. No general full Apromore/enterprise/complete BPMN promise. No new feature scope or deadline extension: original deadline2026-10-10 19:37:57UTC, protected final90minutes unchanged.
