# PM independent RESTORE01 position before resume proposal

PM /root/pm_s7, fixed Council seat. Invitation received before common exact resume proposal. This is an independent product/acceptance position, not QA replay, final vote, STOP closure or release permission.

## Fact

Fully read and independently hashed actual QA STOP815E902CBED726412BD0FADD2C852C42ABAB12FAE41DD6CAF367E9A52ECA1B08 and TD source finding2E8F28D4EA23E58DC0D5DAC84C6FB77709122642B6E7593CD672F23A6338E0A4. D2 source4a19adcb676912b4b0a8e5bd9c1ab463cba03dd9 backed up/restored successfully at HTTP level but restored original download returned422 repository_corrupt: provenance was put in mutable log_state and source was plain EventLog, unlike the valid original envelope. This is a mandatory conservation failure even though restore returned200. The original data and isolated failing attempt remain preserved; protected installations were untouched.

Read corrected source diff through d29b623d70179d6dab2863464f70aef5c97f0d47. normalized::split_repository keeps strict serde/project/log/model/job validation, then delegates to canonical repository_v2::prepare rather than manually separating fields. The test join calls the real production decode_log instead of reverse-building its own incompatible representation. This addresses the actual representation divergence without weakening lazy decoder validation. TD independently supports the same mechanism; its conclusion is source-addressed/pending execution, not acceptance.

Actual before-fix regression stdout/process was read: exit101 demonstrates the valid-provenance restore cause before repair. Actual test11 process/log confirms exit0 and the named restored_provenance_uses_same_immutable_encoding_as_new_import regression PASS. Debugbuild03/clippy02 completed exit0. Ordinary tests include explicit ignored PG scenarios; they do not prove actual HTTP restore/restart. Root repair's first follow-up compile/test corrections remain separate history, not invented first-attempt success. Independent fresh actual QA restore/restart is pending at this position.

## Risk

The operator expects a valid backup to recover original source and explanations; silently unreadable restored provenance invalidates R2-03/04 and R3-03 conservation and blocks public runtime acceptance. A helper that encodes and decodes its own broken layout can falsely pass, so production-decoder tests matter. Canonical prepare must be exercised on a fully deserialized repository with serde-skipped persisted/deletion state defaulting empty; otherwise a partial-delta encoding could omit records. Correct source and unit PASS alone cannot show transaction/restart/source/audit/folder/calendar conservation or old plain-source compatibility.

## Proposal

Keep affected new features/publication stopped until independent QA executes a fresh exact corrected candidate: confirm/import → valid backup → restore into new ownership → source/history/folder/audit/calendar/export conservation → actual restart and reload. Preserve malformed/tampered/hash-valid semantic negatives, controlled refusal and no partial SQL. Preserve old plain-source compatibility and original failed attempt. TD must independently read actual QA closure evidence and check cause/remaining limits; then Council may vote on one exact targeted resume proposal. No vote before that proposal and no silence as FOR.

If those gates PASS, support narrowly resuming previously authorized Sprint08 work/final candidate preparation. This would close RESTORE01 only for proven corrected path, not grant package/public delivery, human acceptance or full R2–R5 closure. Cleanup may continue as read-only design while STOP remains; no protected mutation or cleanup implementation is authorized by this position.

## Basis

The repair consolidates the same production source/provenance encoder used by new writes and invokes the real lazy decoder in the regression, reducing duplicated semantics rather than manufacturing compatible output. Actual failing-before/passing-after evidence provides a cause-specific check; independent HTTP+PG restart supplies the remaining operational evidence. This proportionate targeted Council review protects mandatory restoration without refreezing every unrelated draft. Fullservice/SplitMiner BLOCKED, DISK01 OPEN and native5.1 backup UNVERIFIED remain unchanged.
