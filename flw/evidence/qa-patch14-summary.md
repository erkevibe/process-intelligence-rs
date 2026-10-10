# Independent patch regression (draft)

qa_process fully inspected contract-tests-14.log: core8/HTTP8 passed including actual oneshot22MiB413 and1-based timestamp context. No assertions weakened. Patched live port3000 curl Expect100Continue observed final413 with0bytes uploaded, exit0, unchanged previous export; invalid timestamp422 showed «Трасса1, событие1» (with spaces in actual UI). Safe qa-patch-regression.json records checks; raw response headers/body private .local/qa-admission/22MiB-fixed.*.

Actual browser patch14 replay passed fourteen scoped assertions, including22MiB client guard with clear20MiB error, zero requests and unchanged graph state. Raw report private .local/qa-browser-patch14/report.json. This closes QA-LIMIT-22M on active patched path, pending frozen candidate clean replay; original baseline SHA was not amended by observation.

app14 request_completed INFO records now observed with request IDs, statuses and durations. Earlier app logs had INFO disabled by inherited RUST_LOG=warn, so missing request chronology was disabled coverage, not evidence of absent requests. Current app14 snapshot inspected only by tail: truncated. Root events/task cards still do not constitute continuous complete observation.
