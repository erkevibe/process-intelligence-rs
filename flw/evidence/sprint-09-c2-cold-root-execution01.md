# Sprint09 C2 Windows PowerShell5 cold execution and browser replay

Candidate remains source `b4edef34b083d1cb7737cf648f1c051eeb94127a`, EXE SHA256 `7FC3812772D64D9A74EEC55413C41C6C189167FFEB279EFCE2613CA7FD6AD195`, ZIP `EDACC3B836B5660439FFAA684A3D92451512731ADD9AAE89F0703A6E400C975A`. This is Root execution evidence awaiting independent acceptance, not release approval.

## New extraction and actual cold bootstrap

An owned SID-only protected installation was freshly extracted under `cold-c2`; all1737 files including manifest were independently checked against the frozen ZIP, with no reparse traversal or ZIP symlinks. Preparation proof SHA256 `98B716431B31221066B4832F79B87F7C3EAE1A66C8C88C45B3F96A6DA684BCF3`.

The first launcher omitted the documented process-only execution-policy argument and was refused before the packaged script or database launch. The second inherited PowerShell7 module paths into Windows PowerShell5 and failed before database launch on unavailable Get-FileHash. Both failed instruments and outputs are retained; their wrapper exit1 does not establish an uncaptured child exit. Controlled native5 probes observed failure with the inherited module path and success with only Windows built-in module paths. The third launcher used the documented argument and a child-process-only built-in PSModulePath; no machine policy, environment, module or package file changed.

Actual Windows PowerShell5 started new PostgreSQL5458 PID40212 at `12:57:18.9570660Z` and exact C2 app3078 PID21144 at `12:57:20.3817130Z`. Health200 version0.7.1 and empty setup200 were observed. Ready proof SHA256 `5FBC66327BAB8FE8C73A4004A4427051B962389F2B84673F6494FB00DD25EB9E`. Its long-lived native5 parent remained pending while the application ran; no native0 parent completion is asserted.

## Preserved failed browser04 and separate empty replay

Browser04 actually created a first account and imported manual.xes, but its assertion incorrectly expected raw-original200 for a strict prior-style import that intentionally lacks provenance. Actual original_unavailable422 was retained and the whole attempt remains FAILED. Its account, log, database and artifacts were preserved. No password reset or direct Auth mutation was used to repeat it.

A NEW empty `pi_restore_s9_cold_browser05` was created on the already bootstrapped owned PostgreSQL5458. Creation PID50340 was captured, native0, proof SHA256 `610B00F4DC41BCD66058231AD64CD9A3A88A7BFED4C3381A9B41678D503624A8`. Native5 started a separate exact C2 app3079 PID40032, creation `13:06:57.0299400Z`; health200/setup200 proof `67CB724C8C80011B5E97B131B14B65557F3972D8D22E4E1D5AAC9B75B78718E9`. This phase is a fresh database/UI replay, not a second empty PostgreSQL bootstrap.

Actual headless Chrome155.0.8059.27 through bundled Playwright completed browser05 at `13:07:58.362Z`: first-account form, manual import, graph3nodes/4edges, full export4cases/10events with fixture SHA256 `A692BD173E7CEDF21E5D0ECC6324803562E7486D0CA2C6C4750A9BC350C9ECA6`, committed log_imported audit policy1, and the expected original_unavailable422. No external browser requests or page errors were recorded. Root visually inspected the saved complete graph screenshot. No CUA/native desktop automation credit is claimed; CUA initialization failures occurred before browser work.

Actual Node53156 creation `13:07:55.5648074Z`, end `13:07:58.3986309Z`, native0, exact helper SHA256 `CF992798FEB2C7B53431D234F3F668F6608CE21C85DCB2BFA0BBEC699E5ECC11`; both streams were empty. Native proof `473BD4DD2873A879187362A1590244FE2F5F951EE7ED2AA4FB49FE4B6E51C2CD`; report `73BDBD2EEDFD3B35ACDC1E038B44664FDF772292EE5D02A7F3D2015AA78BBBB7`; export `BB968B128607FD6D94AF609D1742D8FDC3E293C307AA9B087B44B2A0A6E038CE`; audit `673E999E4019260FB5D9E9434253D08B80B2DC9F68E7D1D4930484963FA05B8E`; expected original refusal `962AB217D34DC16EA5618147940566F2C9FBF4433C108CE78D5B6E6DF5A88AB0`; graph PNG `B15D1EDBEBD07766F87639D69EF166AED2347F546FEC614E3263731DF569F5D9`.

Private evidence remains under `.local/sprint09/qa/cold-c2`; no credentials, cookies, complete Auth documents or real user data are published. Own3078/3079/5458 remain separate from human3080/5455 and all protected installations. This finite smoke does not accept full restoration, fault gates, enterprise readiness or R3 completion. Independent review and final native-parent closure remain separate obligations.

## Additive owned closure and capture limitations

At13:38:35 the owned PostgreSQL5458 was stopped with identity-bound pg_ctl PID51280, native0; listeners3078/3079/5458 were absent, all data and evidence retained. Proof SHA256 `6A27F5A54C9FB9A6E16E0F9F7E733D08DDFD6760B61567562898234B100F0A00`.

The initial closure script safely refused before any stop because PowerShell7 auto-decoded JSON timestamp strings as DateTime. A distinct closure used DateKind String without weakening PID/creation/path/hash checks, intentionally stopped only its two application handles, and waited for both native5 parents. It then failed hashing redirected stdout still held by the owned PostgreSQL descendant, before persisting those application/parent exit values. The corrected PG-only closure did not repeat application stops. Consequently those native exit values remain **missing**, not0; closure and the intentionally stopped application's outcome are separate from the earlier actual successful startup/browser smoke. Both failures remain in process coverage. Final acceptance must explicitly assess this limitation rather than claim complete successful native-parent capture.
