# C06 scalar-date bound clarification

Exact source: 3ba4cbbd6ffdc00c1185eb726dd01445eba86a9e. Additive clarification to immutable developer handoff and TD prefreeze wording; no implementation change or actual test claim.

storage.rs ResourceSummaries uses PostgreSQL length(document->>created_at)<=64, which counts characters. web.rs deserialize_created_at uses text.len()>64, which counts UTF-8 bytes, then strict RFC3339 parsing. A valid RFC3339 date is ASCII. For malformed Unicode, up to64 Unicode characters may pass the SQL projection and transfer up to256 UTF-8 text bytes before strict rejection. JSON serialization framing/escaping and allocation overhead are additional bounded overhead; this is not a literal64-byte wire/allocation cap. Non-string/over-character-cap values project JSON null and the strict decoder refuses them. Absence alone projects SQL NULL and remains historical unknown.

Therefore the developer handoff claim of a64-byte SQL transfer cap was too broad for malformed input. The approved P4 contract requires bounded small scalar metadata, not an exact64-byte SQL cap; no mandatory product blocker follows from this difference. The same-list metadata decode may refuse all rows on malformed date rather than label it unknown; that is strict behavior, not validated healthy payload.

Scalar projection avoids full heavy document transfer/deserialization into the Rust resource cache. It does not prove PostgreSQL never physically reads/detoasts the underlying JSONB record. No TOAST/disk-read or totalRAM measurement is claimed.

Pending independent actual negative:64 copies of Я are128 UTF-8 bytes, should be refused before restore publication with complete SQL conservation under the prospective QA contract. This note does not report that unexecuted test PASS. No source/package/user database action performed.
