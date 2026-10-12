# Stock restore/crash comparison — proposed finite oracle

This adds a named comparator for new stock installations on the pinned PostgreSQL18.6 binary. It does not change the original cleanup/SQL5 capture SQL, its614304123-byte domain, source eligibility hashes, corpus, budgets or acceptance conditions.

Stock-flow02 failed its original raw equality check. Independent QA established that the only difference between source and each new stock restore was physical sequence log_cnt31→0: last_value2, is_called=true, all other full raw managed/Auth rows and the sequence definition were equal. That failed attempt and its raw captures remain unchanged. This observation does not by itself accept stock recovery.

PostgreSQL permits gaps in assigned sequence values after aborts/crashes; sequence allocation is not transactional. [PostgreSQL18 sequence documentation](https://www.postgresql.org/docs/18/functions-sequence.html). The pinned18.6 implementation prelogs32 values and stores the reserved future last_value with log_cnt0 in WAL, then keeps the intended live last_value/log_cnt in the page. [PostgreSQL18.6 sequence.c](https://github.com/postgres/postgres/blob/REL_18_6/src/backend/commands/sequence.c).

The new finite comparator retains both complete raw captures and reports their SHA, raw equality and both full sequence rows. All non-sequence raw rows remain byte-exact, including Auth, metadata, values, versions, ledger, markers and sequence definition. Required definition: positive bigint, start/min1, increment1, CACHE1, max9223372036854775807, no cycle.

- Negative request: entire original raw snapshot equality remains mandatory.
- Stock restore: last_value and is_called must match exactly; physical log_cnt is reported separately, within the pinned0–32 range.
- Controlled whole-service crash with no intervening allocations: last_value must be unchanged or exactly the recorded prelogged reservation last_value+log_cnt. If last_value advances to that reservation, log_cnt must be0; otherwise log_cnt may remain unchanged or become0. is_called and definition stay exact. Arbitrary increases, decreases and business/Auth changes refuse.
- Untouched verification copy and restored-copy startup before login: entire raw snapshot equality remains mandatory.

The comparator does not claim complete physical sequence equality across restore/crash, cross-version compatibility, arbitrary caches, infrastructure HA or whole-cluster equality. Full byte-equal exports/original XES/import history are separate actual checks after login. Post-login Auth mutations require their own declared delta for stronger acceptance. Nine finite synthetic regression scenarios exercise allowed transforms and refusals; real native/HTTP/state results still need independent review.
