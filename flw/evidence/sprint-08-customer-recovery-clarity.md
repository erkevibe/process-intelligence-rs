# Sprint08 — Customer bounded operator recovery clarity

Independent document/contract position in response to Root's renderer/report inspection. No new browser execution, producer/source/package change, STOP or final vote. Existing exact-package browser acceptance does not prove lost-ack exactly-once recovery.

The current manual recovery limitation must remain visible and R2-03 must remain OPEN for any original requirement that needs operator-facing durable operation identification/exactly-once or complete lost-ack proof. Preview operation UUID equals its token, but is visible only in the full report link URL/hidden form; preview JSON lacks the UUID. History labels the UUID only after successful persistence. A token in a URL is not equivalent to a readily visible operator identifier, and a user may not have saved it before an uncertain result.

Recommended current guide/release wording:

Before confirming, save the complete preview report and copy its download link. The UUID between /xes/previews/ and /report is the operation identifier; the JSON alone does not currently contain it. Keep the original file and its full SHA256. If confirmation reports an uncertain result, do not confirm again or upload the file again. Restart, inspect saved journals and their import history, and reconcile operation UUID together with original full SHA256, filename and confirmation time. A matching journal's history is the persisted evidence; absence from an initial glance is not proof that no commit occurred. If the outcome cannot be reconciled, keep it unresolved rather than retrying blindly. Automatic deduplication after restart is not implemented.

Filename/time alone do not establish identity and same-hash reuploads can be intentional different operations; the saved operation ID and policy/history binding matter. Documentation makes existing manual control clearer but does not create durable discovery/exactly-once guarantees. Future UI should label and export the operation ID before confirm and provide a supported reconciliation path; that requires separately reviewed runtime tests/new candidate, not edits to this frozen package.

This limitation is proportionate to the accepted fail-closed/manual recovery contract if clearly disclosed. It is not a newly demonstrated data-loss or permission failure, and does not by itself reopen the closed restore cause. Human acceptance and full-stage status remain separate.
