# Customer independent operator-shell position, before final proposal

Owner /root/customer. Read PM shell position, updated STORAGE_V2 and C1 designation. No runtime/package edits, no vote and no blanket A08/A09 acceptance. Whole final QA/TD proof still required.

## Independent customer judgement

The customer requirement is a safe executable backup→newrestore→migration→start route that preserves existing work. It does not inherently require every helper to run in built-in WindowsPowerShell5.1; S4-P1 separately requires native Windows installation. Therefore an actual complete stock PowerShell7.6.5 operator chain plus actual native5.1 Start can satisfy those functional outcomes in a clearly bounded supported configuration. It creates an additional prerequisite and support limitation that must be disclosed before a user begins recovery, not discovered during it.

Native5.1 backup is UNVERIFIED: suspended/no-execution processes and private antimalware-blocked harness do not establish product incompatibility or successful backup. Never disable protection or encourage exclusions to get a PASS. No general Windows5 helper compatibility is accepted. The confirmed exact7.6.5 result cannot be transferred to untested shell versions.

## P0 user-facing delivery conditions

1. Release-front/README must prominently distinguish Start uses native5.1, tested backup/restore/migration uses PowerShell7.6.5. Link the current pinned operator guide and official Microsoft installation instructions; do not silently assume a standard user has Codex-bundled pwsh.
2. Keep full consistent newinstallation/newcluster/newrestoredDB/sameDatabase+PGPort commands and restored-account login. Do not instruct copying secrets/config alone or redirecting the original live database.
3. Frozen canonical ZIP documents are a build-time snapshot. If older guide commands name5.1 backup, explicitly call this out in release-front and point to corrected pinned guide. Do not modify manifest-protected files locally or silently repackage without a new artifact identity.
4. Exact A08 evidence must show complete auth/schema/normalized records/version/hash equality and atomic corrupt/existingtarget refusal; A09 independent exact nativeStart/browser/provenance remains distinct. Docs do not substitute these proofs.

## Residual and position

Acceptable as explicit bounded operator support debt if final proofs and P0 disclosures are met; not a reason by itself to discard the actual safe7.6.5 functionality or demand a new human permission. Unverified5.1 chain remains a future independent compatibility/environment task with owner and closure: actual cold/full native5.1 helper chain without weakening protections. This is not a final release vote; missing disclosure or missing safe recovery evidence would remain a delivery barrier. Existing user installs and protections untouched.
