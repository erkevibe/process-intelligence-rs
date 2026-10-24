PUBLIC SERVICE EVIDENCE — SPRINT 18

This folder contains full typed observations of OWN SYNTHETIC fixtures, not native
console logs, user data, upstream source, JARs, JDKs, or executable payloads.
Every signed integer and float numeric JSON token is retained verbatim by the
publication transform. This includes i64 extrema, values beyond 2^53 and -0.0.
Absolute workspace paths become workspace:// aliases; ephemeral lambda addresses
are aliased. Exception message text is withheld; original UTF-8 message SHA256 and
exception classes remain. Original observation hashes and sanitized file hashes
are distinct and recorded. Native stream byte counts/hashes/exits/EOF flags are
published; the original streams remain private. These hashes are provenance,
not a claim that omitted native streams can be independently recovered here.

To reproduce the FIELD COMPARISON, place this directory at
evidence/sprint18/public-service in a checkout containing the original frozen
fixtures/oracle-public-service and tools/oracle/compare-public-service.mjs.
Use Node 24 with JSON reviver numeric-source support, from the repository root:

node tools/oracle/compare-public-service.mjs --matrix evidence/sprint18/public-service/reference-index.json evidence/sprint18/public-service/rust-index.json NEW-comparison.json

The result will bind SANITIZED observation/index hashes rather than the private
original hashes. Public indexes retain original hashes separately. Compare full
typed fields and the explicit mismatch/null/rollback findings; do not treat new
index hashes or path aliases as an algorithmic difference. The copied fixtures
inside this folder are byte-identical backups of the repository fixtures.

NATIVE REPLAY IS NOT PROVIDED AS A READY PUBLIC ENVIRONMENT.
It depends on the separately built canonical Apromore core commit
bbf24dfd43e72d6992392465f875a4367cbe792b, all real runtime dependencies, pinned
JDK11 and Gradle7.1.1, plus the declared selective Spring/Hibernate/H2/FILE/cache
wiring. canonical-inputs.json records ordered classpath aliases and hashes;
it does not download or rebuild them. The public-service runners contain the
fixed S18 freeze 2026-10-21T22:55:42Z and private SID/path/resource controls.
Future native execution requires a NEW reviewed workspace, deadline, mechanism,
configuration and dependency binding; current private paths are not a portable
bootstrap. No expired guard is removed or bypassed by this publication tool.

SCOPE AND FINDINGS
Actual unchanged public importLog username/perspective=false path only, with
real reachable Spring transaction/JPA/H2/FILE/Ehcache/APMLog dependencies and
explicitly unwired unreachable services. No Portal/HTTP authentication,
production MySQL, perspective=true, complete service wiring, whole R2, or
enterprise parity claim. Ten observations retain the earlier non-null adapter
identity; two use a null-capable observer. carry.json proves the exact own-source
repair and unchanged compiled classes; there is no single-binary batch claim.
DB rollback/unique-constraint failure leaves observed file/cache side effects.
The all-filtered log persists but returns null after cache/database reopen.
Default XLog name trailing whitespace changes after storage reparse. Raw
Rust4PM metadata and application preview admission are separate profiles.
Frozen failed hypotheses and actual nulls remain failures/nulls, never fabricated
empty models or silently normalized equality.
