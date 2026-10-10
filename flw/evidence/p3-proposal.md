# P3 exact proposal

Proposal recorded 2026-10-10 06:20:29 UTC, following the earlier invitations and independent positions.

Accept b12554fcda6ff801392326bea85f0714221a9246 as the completed local R1 prototype within the first eight-hour sprint budget, subject to explicit final independent QA and TechnicalDebt acceptance and actual council majority. Production code remains frozen at this SHA. Subsequent reporting commits may update documentation/evidence only and must preserve production source identity.

Acceptance scope: mandatory AC01–12 plus implemented optional AC13–14. Evidence comprises exact-source fresh checkout, pinned setup, fmt/clippy, 30 contract tests, browser base14/optional10/stale5, small corpus20, release admission11 and packaged browser14. Linux push and PR CI conclusions are success; raw CI logs were not collected.

Exact release benchmark on Ryzen AI 9 HX 370, Windows 11 Home 10.0.26200 x64: 10,000 events / 1,000 cases / 20 activities; server parse+analysis 25 ms, HTTP upload wall 31.70 ms. The 5-second goal is achieved in this measured scope. Process-lifetime peak working set is 109,658,112 bytes; precise per-job RSS and its 512 MiB target remain unverified. This qualification is permitted by AC11 and does not imply a total memory ceiling.

No blocking debt remains in the independently reviewed R1 paths. Accepted limitations: in-memory last-eight logs and bounded job history; restart loss; cooperative cancellation with an uninterruptible third-party parsing stage; first-200-event UI preview with complete JSON; local loopback deployment. Minor Customer UX findings move to R2 with their recorded proposals. AC15 legacy equivalence, persistence, multi-user security and enterprise readiness remain unverified future work.

After the independent gates and majority pass, publish the evidence, merge the reviewed PR, issue a v0.1.0 prototype release with checked Windows package and source identity, and leave the actual local application running for the user. Report actual start/end and elapsed wall time; do not represent the full eight hours as consumed. Continue the enterprise roadmap through later separately scoped iterations.

The council does not impersonate the human user's final acceptance. Existing user authorization permits development, public repository delivery and execution; no additional authorization is being inferred from a council vote.
