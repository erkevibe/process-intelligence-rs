# Independent draft05 project-backup trust review

Owner `/root/qa_business_s9`, coordinated independent QA. Exact draft executable SHA256 `095103C2BBF7CD1E4B89881A02ECCA589D82962974DAE110ABED0394EA424A9D`. Only its owned HTTP3073 app was replaced after checking stored PID, process creation and executable path. Old draft04 proofs remain preserved.

The ordinary-client spoof counterexample now restores as unverified imported history. Actor/time/project/resources/revision/sequence remain, while policy and committed outcome are absent and origin is `project_backup_unverified`. Restore200/open303/export200; no forged committed event in export. New input SHA256 `7be67480aa832e6ac65fe86e571a527bab3476528e555b210b6857c7e8f442e6`.

Additional actual native0 checks:

- Independently recomputed authentic `project_backup_restored` parameter digest matches original canonical repository digest before trust normalization or project-ID remap, plus actual imported total/retained counts and server import policy.
- A second import of already unverified history remains accepted and unverified; legacy None/None history imports as unverified without claiming old success.
- Imported-origin plus trusted policy/outcome, and unknown origin, both refuse with complete managed PRE/POST equality.
- A subsequent genuine folder mutation appends a distinct server policy/committed event with no imported origin; the prior imported event stays unverified.
- The audit page uses “История действий”; JSON distinguishes imported and genuine events.

Private evidence: `.local/sprint09/qa/business01/backup05-spoof-*`, `spoof05-pre/post.state.json`, `import-policy05-results.json`, `ip05-*`. No credentials, sessions or payload values are published here.

This is an affected draft-path observation, not final acceptance. The earlier draft04-poisoned test database contains historical false-trusted events and cannot prove a supported clean upgrade. Final acceptance must start a fresh bootstrap database or a separate legitimate supported public stock recovery. Restart, full stock backup/new verification restore, final exact package repetitions and the remaining original business/lifecycle corpus are still pending. Earlier draft04 retention outcomes are not transferred to this changed binary.
