# QA actual additive audit-import policy vote

UTC: 2026-10-11T10:10:26.9141951Z
Proposal: docs/SPRINT_09_AUDIT_IMPORT_POLICY.md
SHA256: 47B40B17E5F554807C3DA97F9CC4B552730837D53DC7324D70AC41D04D6D5250
Vote: FOR

Independent business QA reproduced an ordinary authenticated upload presenting forged journal content as trusted committed. Full proposal read and raw SHA independently verified. The proposed normalization preserves historical content/order/counts while removing trust that client-controlled backup bytes cannot establish. Genuine server restore audit must remain atomic and bind pre-normalization canonical content; operator stock recovery must stay byte-preserving.

This vote authorizes the bounded policy repair only. It does not accept the changed runtime or any criterion. Mandatory affected negative/repeated-import/current-role/CAS/restart/full recovery cases and fresh candidate binding remain required. No administrator-tamper-proof or complete security-ledger claim.
