# C2: known COMMIT followed by receipt write failure

Frozen source b4edef34b083d1cb7737cf648f1c051eeb94127a; Windows executable SHA256 7FC3812772D64D9A74EEC55413C41C6C189167FFEB279EFCE2613CA7FD6AD195. No product or package modification.

Root executed the separate synthetic-copy test on 2026-10-11 at 13:51:55 UTC after TD independently reviewed the Observe-FIRST run. The observer saw real server COMMIT at 13:51:53.772, created the fixed private receipt-path directory at 13:51:53.779, then forwarded the acknowledgement. Verify exited 0; Apply exited 4; observer and retained parent exited 0. The client reported cleanup_committed_receipt_failed with automatic_retry=false. Complete source snapshots changed only by removal of the two approved legacy KV candidates; complete verification-copy snapshots were unchanged.

Private result SHA256 BA04EDCB1E139B3D7A720365D9F15778BDDF9F945AEEE0E18E418FDB3BC672D4; complete trace SHA256 9DEE15AAA007133869E955A89DC9B0C4E754BA8F8353FA7FE3A67D5F7097939F. Independent TD actual full-file/raw-value review: [receipt4 actual review](sprint-09-td-receipt4-actual-review01.json), SHA256 C81FED53904BF2232F700241A13335EBDB3252B533950498435FE2DCC36EC2E1.

This supports only the bounded known-commit/receipt-failure case. It is not lost acknowledgement, a general exactly-once guarantee, an overall acceptance, or permission to retry cleanup automatically. Named native captures do not establish every transient descendant's identity. Protected installations were not used.