# Sprint07 — Customer position before final proposal

Reviewed complete docs/SERVICE_IMPORT_PREVIEW.md and all eleven public comparison cases through a bounded structured projection. The initial raw JSON tool output was truncated; subsequent projection captured every case's status, source counts, resulting cases/actions, legacy counts/actions and idempotence. Confirmed safe output hashes: reference-results.json CE686375AAD6F92B458D556ADD466C768F272E218DEA2274CF5F45CD95313065; rust-comparison.json 9A9D78E55329F8A53BA6ABC3527DB057EAFA03B7D852256205592C8BA1461CB8. This is document/result review, not an independent executable replay or final vote.

| Customer requirement | Position on candidate |
|---|---|
| S7-C01 narrowed by exact plan | Documentation explicitly distinguishes mechanically extracted unchanged validateLog/isInvalidEvent method execution from the original complete class/service/Portal. Actual source-slice verification and invocation rely on separate independent QA, not Customer re-execution. |
| S7-C02 opt-in | Separate public library API/developer example is clearly stated. No HTTP/UI integration, default import change or user data mutation is claimed. Accept the limited developer result; user-visible integration is deferred. |
| S7-C03 explained removals | mixed case retains events ordinal0 and4 while explaining missing activity/time, unsupported lifecycle and empty trace removal. Source-order preserves case-1 after removing case0; all-removed and whitespace-lifecycle return fully_filtered=true. Counts/actions are visible. |
| S7-C04 no invented source events | Default complete is a separate action; documentation's original/action/result table satisfies the emotional advisor's clarity criterion. No invented timestamp/activity is shown. Source order is explicit. |
| S7-C05 explicit refusals | Six cases disclose strict admission divergence, including invalid date, duplicate key and wrong name/time/lifecycle types. These are not manufactured parity. Fully filtered cases are not described as useful mining output. |
| S7-C06 fixed evidence | Eleven public cases report manual_pass; five supported policy-equality and six explicit admission divergences remain separate. Independent fixture immutability, limits/cancellation and previous-regression execution remain QA responsibilities and final conditions. |
| S7-C07 practical documentation | Reproduction and before/action/after example are concrete. Checked final CI, guarded promotion and independent public delivery are still mandatory; this position does not declare them passed. |

Customer considers the limited developer preview valuable and its proof boundary honest. The reference repeatedly reports identical post-first/post-second state on successful selected inputs; Rust idempotence/attributes are explicitly narrower than full XES round trip. No UI capability or overall Apromore service compatibility is inferred.

Next useful customer step is a separately scoped import-preview screen: upload once, show original versus proposed counts/actions, highlight fully filtered/strict refusal, and only after explicit operator choice create a new imported result while preserving original source/hash and auditable policy/action record. This is a future product requirement, not extra approval needed for already authorised current development, and not permission to overwrite existing logs. Preserve ordinary strict import and existing RBAC/admission limits. Full runtime persistence/UI/cancellation tests and an actual new frozen package would then be required.

DISK01 cleanup and native5 backup remain open, independent operational work. Final Council vote awaits the exact F1 proposal and completed independent QA/TD/CI evidence; human final acceptance remains separate.
