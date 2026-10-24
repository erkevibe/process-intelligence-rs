# Sprint09 C2: isolated identity refusal checks

Root executed the fixtures. The independent ProcessLogAuditor separately reviewed the complete retained states and native outcomes. This is a bounded result, not acceptance of the complete cleanup criterion or a release.

Candidate: source `b4edef34b083d1cb7737cf648f1c051eeb94127a`, version `0.7.1`, executable SHA256 `7FC3812772D64D9A74EEC55413C41C6C189167FFEB279EFCE2613CA7FD6AD195`. Only newly owned private PostgreSQL clusters on ports5456/5457 were used. The test database is `pi_restore_s9_c05_c2physical01`; shared5450 and protected installations were not changed by these fixtures.

## Physical identity alias

The small stock archive was restored into the new source cluster, then the source was cleanly stopped and physically copied. The closed-copy helper retained the native `pg_controldata` stdout/stderr and a complete file comparison report. Source and clone were started separately with current PID, creation time, executable, datadir and listener checks. Actual SQL readings returned the same system identifier `7695386433917935308`, database OID `16385` and database name. A new packaged stock backup of the actual source bound archive SHA256 `633A3309104AEE72FA64B441F3984755DF0774334EE22172C61DC006DD6E4592`.

The actual frozen executable exited1 with `cleanup_identity`. No plan or Apply was produced. Both full PRE/POST pairs remained identical: each80,059bytes, SHA256 `4C8839B40D25409DF0031DDE7C6404C797C5239C132E6ACA29D6E1DB7723C9E8`.

Private execution proof: `.local/sprint09/qa/physical-c05-c2/c05-identity-alias01.json`, SHA256 `93006006799EF5770EAD0D56FC4700DF54A8C13DDEEF3720135E16DB5DC7C3D3`.

## Unavailable identity privilege

The original function ACL was captured before an explicit fixture-only revoke of PUBLIC execution of `pg_catalog.pg_control_system()` in source5456. The effective application privilege was checked. No fallback grant was made.

The actual executable exited1 with `cleanup_storage_unavailable`. No plan or Apply was produced. Both complete PRE/POST pairs, including function ACL and effective privilege, remained identical within their own cluster: source80,126bytes/SHA256 `C837245CE0474EF68BAE3229A4DCD1B1875A18DD4412EA1FA29A91BDEB82617A`; clone80,106bytes/SHA256 `E4ACD1E0EF4DCE31C3F9D08FB7BC13EC5202A6C72C2D763DF0C1F22552F05C28`.

Private execution proof: `.local/sprint09/qa/physical-c05-c2/c05-identity-privilege01.json`, SHA256 `9800A01EFC1DFEA47020C3D7BC8C30C409C151518C3BC0ECC7D547249AED335A`.

## Independent review and retained preparation failures

The independent auditor read/hash-checked62 retained inputs and recomputed all four complete PRE/POST byte comparisons, including catalog definitions and semantic sequence state. Review: `.local/sprint09/qa/c05-c2-independent-review01.json`, SHA256 `3CA56DEB23B525F994FFC6C766C614BF6ABCDC3A1D0836F5C87F0D655339860E`.

The independent technical auditor separately verified those62 inputs/four pairs, the actual native control shutdown, and1296 unique safe relative copy entries. Its review is `flw/evidence/sprint-09-td-c2-finite-c05-review01.json`, SHA256 `9D88326AF3693E65F20B40E24F20ABB0D677B0C9E07AA3E629D6280C7FA47464`. The copy report contains one hash/length list; original source/destination equality is attributed to the reviewed helper and captured execution. Two independently persisted lists or reconstruction of historical closed bytes after server restarts are not claimed.

Two initial lifecycle attempts refused inherited rather than explicitly protected datadir ACLs before PostgreSQL launch. Their original native1 parent proofs and stderr remain retained. Root then explicitly protected only the newly owned directories and used separate parent output names for the successful attempts. These preparation failures are not relabelled product failures or successful launches.

Long-lived descendant pipe captures initially remained pending; after the reviewed, identity-guarded source and clone shutdowns, the actual start-helper parent captures completed natively0. Both new servers are stopped, with data and evidence retained. Native process records cover named launches and do not claim an exhaustive transient descendant inventory. No C1 result is transferred to C2, and R3-01/R3-02/R3-04 remain OPEN pending all remaining gates.
