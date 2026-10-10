---
name: project-payload-admission
description: Change this project's Rust demand-loaded payload ownership or heavy HTTP/SSE admission, preserving durable resources and actual slow-response backpressure.
metadata:
  origin: FLW-SkillManager
  source_problem: S5-QA-BODY01 / CACHE01
  verified: 2026-10-10 / draft04-E704-constrained-ordinary-and-CompletedSSE
---

Keep durable catalog ownership separate from clean payload residency. Missing or evicted log/model entries never mean SQL deletion; explicit deletion sets and successful CAS acknowledgements determine durable changes. Weak baseline identities and weak single-flight results must not become hidden strong owners. Clear transient dirty maps only after successful persistence. Requested resources receive strict validation; unrelated unloaded payloads may remain deferred.

The current retained cache contract is global128MiB charged estimate/eight entries, independent of project count and separate from active requests, jobs, response allocations and whole-project backup. Charge owned capacities and overhead consistently; oversized valid resources bypass retention without becoming unusable. Verify versions and current authorization on hits, and apply actor-specific views outside the shared base. These limits and a lower working-set measurement are not a physical-memory cap.

Tie a heavy response's lease to both active blocking work and outgoing data ownership. A request disconnect does not stop its blocking worker. Body EOF does not prove transport buffers were released. Bytes owners shared by clones/slices must carry the same lease, with no timers or synthetic diagnostic reservations.

Do not yield one giant JSON/SSE frame: Hyper checks its buffer ceiling between frames. This project's verified repair yields frames of at most16384 bytes while retaining the unyielded tail and its lease. This preserves incremental backpressure even when a single application allocation is much larger than the transport buffer ceiling. Inspect the current transport implementation before relying on a buffering constant or attributing behavior to Windows internals.

Completed job SSE acquires a heavy lease only while loading/rendering its analysis output. Sample the per-response carrier immediately when that event frame is produced, before the next inner poll clears it; the pending tail and all output slices then retain its owner independently. Drain the tail before polling the next event. Idle snapshots/heartbeats and waiting subscribers retain no heavy lease. Avoid a carrier/stream ownership cycle.

Verification must distinguish peer application pause from actual controlled receive backpressure. The successful local witness used two real large responses with SO_RCVBUF4096 set before connect, headers-only receipt and zero body drainage: diagnostics2, third immediate503, then independent socket close releases1/0 and healthy subsequent requests. Repeat separately for actual Completed SSE, fully consumed analysis/terminal output and post-consumption release, plus two real nonterminal idle watchers and cancellation. Do not manufacture running job state in SQL or use a small body as the oversized witness.

Preserve complete output bytes/semantics and exact EXE identity. An owner-only repair passed unit tests but failed live paused and constrained receivers; those failures remain evidence. The successful draft witness E704 is not automatically proof for a newly compiled artifact. The observed contract tracks application/transport ownership, not when a peer application reads its last byte; OS allocation/copy/ack behavior remains unproven.

For cache single-flight, two HTTP requests serialized by the project mutex are not overlapping-load proof. The actual PostgreSQL regression holds the per-key test scheduling gate until both real version reads reach misses2, then verifies one load/one flight hit, identical payload owners/full hashes, oversize bypass with zero retention, and unchanged physical record versions/hashes. Keep this gate in the ignored test only, never production delay/fault flags.

Evidence: `flw/evidence/sprint-05-qa-body-finding.json`, `sprint-05-qa-body-closure-position.json`, `sprint-05-qa-sse-scope-clarification.json`, `sprint-05-td-body02.md`, and `sprint-05-qa-singleflight-draft.json`. Read them from the repository's `flw/evidence` directory when revisiting this mechanism. The SSE clarification distinguishes initial undrained output from later full consumption; successful assertion/exit is not a serialized numeric snapshot.
