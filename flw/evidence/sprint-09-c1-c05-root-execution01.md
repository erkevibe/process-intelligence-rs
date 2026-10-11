# Sprint09 C1: isolated C05 execution

Root executed these fixtures; independent ProcessLogAuditor reviewed them separately. This report does not accept the complete cleanup criterion or authorize a release.

The frozen candidate is source `03f0ffd604651e0a0b6d29832f23cbb57ee6a3ea`, executable SHA256 `0DBC999D85A3196F820CBF870D26C38C99A16A1F68B1F75D9336D98F2FA7C362`. Tests used only newly initialized, private PostgreSQL clusters on ports5452/5453, with an unchanged small stock archive restored into a new database. No protected installation or shared5450 configuration was changed.

## Actual physical identity alias

Initialization, role preparation, packaged stock restore, guarded clean shutdown, complete file-copy comparison and the two guarded server starts exited natively0. The two actual SQL identity readings returned system identifier `7695368675841253876` and database OID `16389`. A fresh packaged stock backup of the actual source database bound the cleanup archive; its SHA256 is `260C54135D3D030A0AB06BED672CB44A8FD0F9D8ECAD4D35EEC7BB470285136D`.

Verify exited natively1 with `cleanup_identity`; no plan or Apply was produced. Complete PRE/POST values, versions, migration markers, ledger, public catalog definitions, constraints, indexes, attributes, defaults, triggers, policies and semantic sequence state remained equal in each cluster. Physical sequence cache/log counters are not substituted for the semantic sequence definition.

Private proof: `.local/sprint09/qa/physical-c05/c05-identity-alias01.json`, SHA256 `2DAF2B755860BC9738E22687F07D20EB600B9B8049A9BE878F626403286261C7`.

## Actual unavailable identity privilege

The original function ACL was captured before revoking PUBLIC execution of `pg_catalog.pg_control_system()` only in the new source database. The actual `pi_app` privilege check returned false. This was explicit fixture preparation, not a production permission change or fallback grant.

Verify exited natively1 with `cleanup_storage_unavailable`, with no Apply, plan or permission escalation. Complete PRE/POST comparison additionally included the function ACL and effective application privilege. Both clusters remained unchanged by the CLI.

Private proof: `.local/sprint09/qa/physical-c05/c05-identity-privilege01.json`, SHA256 `9547EE2431BCF2AC8EE345C1C78F0926AEE481256C5AA35AE44462517B9A9416`. The current process/executable/datadir/port/creation and frozen oracle preflight has SHA256 `BA3C804EBB9A7F8A5680051F6F20832A06E28C803939A4372346CA21066D8DE9`.

## Independent review and observation limits

The independent auditor read the complete finite proofs and independently recomputed all four complete PRE/POST pairs. Its bounded review is `.local/sprint09/qa/physical-c05/c05-independent-review01.json`, SHA256 `6923799FDE303D172F7491AE3E31A53FC30F4784E9118556E3E76514D6B58704`.

The original copy helper checked actual clean-shutdown control output internally but did not retain that child's raw control stream. This limitation is preserved. A distinct supplemental execution cleanly stopped only source5452, captured full native `pg_controldata` streams and identity in `closed-control02.process.json`, and made a new full-byte-verified, unstarted copy in `closed-copy02.json`. It does not invent the original missing stream. After that supplement source5452 is stopped; original clone5453 remains running; neither test database nor evidence was deleted. Native descendant inventory is not claimed to be exhaustive.

Other cleanup cases and all three complete R3 criteria remain subject to independent final acceptance.
