# Sprint 02 Customer review before frozen candidate

Reviewer /root/customer, independent of PM and application authors. Read SPRINT_02_PLAN, SPRINT_02_SPECIFICATION, README, ROADMAP; inspected platform HTML renderer and actual QA model.png plus report-before/report-after in .local/qa-sprint02-browser. No live instance used, no clicks/uploads/POSTs independently performed. R1 server3000 was not touched. QA reports are attributed evidence, not Customer-executed tests. No final acceptance vote here.

## Observed facts

- Real model.png shows a readable diagram, named model, revision, BPMN/JSON downloads, Fit control, node label/coordinate editor and separate apply-draft/save actions. Footer/notes disclose observed-variant discovery limits and rejected BPMN semantics. An edited HTML-like synthetic label appears as text.
- QA before report records17 passes for CSV preview/order, filters, calendar export, node edit/XML escape, backup/restore and foreign known-ID denial. After report records4 passes for actual process restart and model/export preservation. Those are scoped QA results; they do not substitute final exact-candidate replay.
- Renderer explains CSV grouping and five-row preview; role labels specify viewer/export and editor/change. Restore text explicitly says new project, current project not overwritten. Calendar explanation states fixed offset and excludes seasonal clock changes.
- Docs distinguish selected R2–R5 slices from full-stage completion, legacy compatibility and enterprise readiness. Windows package instructions explain private .local preservation, PostgreSQL remaining alive and singleton lease. These materially reduce false expectations.

## Concrete frictions

| ID | Fact and user problem | Proposed action | Priority |
|---|---|---|---|
| S2-UX01 | Retain/remove fields require users to type JSON arrays such as ["Оплата","Доставка"]. Syntax errors and quoting burden fall on nontechnical users. | Next UX iteration: activity multiselect or one-item-per-line controls, server retains structured contract. At minimum improve invalid-list error with an example and preserve entered text. | P1 UX, no demonstrated data/security blocker |
| S2-UX02 | No dedicated filter reset control found in log_tools; users must clear case/length fields and set both arrays to []. | Add reset-to-source action or explicit short reset instructions. Source is immutable, so reset should not require reimport. This is outstanding S2-C07 convenience request, not a new mandatory acceptance definition. | P2 |
| S2-UX03 | Model editing has two actions: apply draft then save. Note is present, but a user may edit fields and immediately press save without applying the node. | Verify save behavior and retain visible draft/saved status; later combine field application and save or label the two-step flow more clearly. Existing screenshot cannot establish click behavior. | P2, verification question |
| S2-UX04 | Password form states bytes/UTF-8; HTML minlength counts characters while server contract counts bytes. Non-ASCII users can encounter surprising rejection by the browser. | Explain user-facing minimum in characters consistently, or use custom validation that matches actual contract. Keep byte limits in technical specification. | P2 |
| S2-UX05 | Backup hashes require original file, no JSON reserialization. README explains this; a saved JSON may look editable to users. | Place original-file warning beside backup/restore controls, distinguish backup from analysis JSON; retain corrupt-file atomic rejection. | P2 |
| S2-UX06 | The UI says fixed offset but calls the selector timezone. Users may expect geographic DST rules. | Label fixed UTC offset explicitly and keep current no-seasonal-time note. Existing semantics are disclosed, so this is polish. | P2 |

## FLW emotional input and boundaries

Previously received actual nine perspectives from separate pm_final in sprint-02-customer-plan.md; requested any updated perspectives from that same separate agent. Customer does not simulate or poll the human user's emotions. FLW requires separate emotional-agent perspectives, not a nine-question human survey; no additional user approval is requested inside the authorized sprint.

Mapping observed progress to those perspectives: persisted/reopened analysis responds to Joy/Sadness; route denial evidence addresses Anger; isolated atomic restore addresses Fear; escaped synthetic label addresses Disgust; interrupted jobs remain a required independent QA gate for Anxiety; slice/full-stage disclosures address Envy; explicit CSV/calendar policy addresses Embarrassment; preview helps Boredom, though JSON filters still create avoidable friction. This assessment is observation, not a claim of the human's feelings.

## Barrier position

No Customer STOP or candidate barrier is demonstrated by these reviewed documents/screenshot. UX issues are concrete but do not establish unauthorized access, data loss or false durable success. Missing actual full-candidate proofs remain unverified gates, not Customer PASS. Final role vote requires exact frozen proposal, independent QA/TD conclusions and clean package evidence. Human acceptance and enterprise readiness are not inferred.

## Updated source review before freeze

Read updated renderer/platform.js and specification. S2-UX01/02 are addressed at source level by search/checkboxes/selected chips and explicit native reset. JSON is now hidden transport state. Picker uses textContent, preserves selection across search, version-checks responses and explains that Apply Filter commits the change. Browser evidence of the new picker is still pending; earlier model.png does not show it. Backup original-file warning is added; persistent eight-log capacity now rejects the next import while preserving existing logs, rather than silently discarding stored work. This strengthens the customer durability expectation.

Remaining S2-UX03: model Save submit currently syncs the model draft, not unapplied input fields; current two-step note describes this. A fresh interaction verifier should explicitly Apply Draft then Save. Prefer a future combined apply/save or unsaved-input indicator. Password byte-versus-character/minlength wording remains S2-UX04. Business-duration human table is reported in progress by PM; not claimed observed until actual source/render or QA screenshot is available.

Received updated actual nine perspectives from separate pm_final: Joy seeks connected saved-log/model navigation; Sadness asks original-backup warning; Anger asks hiding viewer write forms; Fear asks selected/full-stage disclosure; Disgust asks escaped labels; Anxiety asks pendingcancel/interrupted messages; Envy asks named baseline without quality claims; Embarrassment asks replacing JSON entry with picker; Boredom asks explicit reset. These are attributed facts/problems/proposals from an independent emotional role, not assumptions about human feelings. Updated source responds to the JSON/reset/backup issues; actual completion requires browser proofs.

No new Customer STOP/barrier established. Preliminary support for the selected iteration remains, with exact final candidate/QA/TD vote deferred.

## Independent position while final package gate is pending

Read sprint-02-qa-acb3cf.md in full. Its exact06 scope reports actual A01–A11 passes, including native browser20, roles5, process restart4 with two same-filename IDs/exports/source hashes, owned durable jobs6, lease3 and private UI3. New UI evidence explicitly includes human-readable one-hour duration, absence of JSON pre, original-source activity picker and exact Unicode/quoted/newline labels. This closes S2-UX01/02 at scoped QA-evidence level; Customer has not personally repeated clicks. Minor two-step Apply Draft/Save and password-byte wording remain accepted UX follow-ups.

The same independent report explicitly fails A12 on fresh PostgreSQL package startup; existing-app success and archive hash do not prove user delivery. Coordinator reports later installer/launcher repairs and exact source c0180a2bf0069b599f112226a10a13f67ce82f17, with fresh package08 still in progress. These reports do not convert A12 to PASS until actual independent clean startup/browser assets evidence on the new exact package exists.

Customer final preliminary position: the selected local application behavior is valuable and its limitations are candid. No new UX STOP is indicated. Mandatory A12 is currently an acceptance barrier, so no final vote or completed-selected-slices claim yet. Historical installer failures must stay visible; final verified repair can supersede them but not erase them. Customer supports proceeding with safe scoped repair and final verification under existing authorization; no further human approval is requested.

If independent exact-package A12 passes and QA/TD give scoped final acceptance, Customer can vote on the exact resolution accepting only the twelve selected slices. This would not complete original full R2–R5, legacy oracle equivalence, arbitrary BPMN/discovery quality, IANA/DST, shared deployment, SSO or enterprise readiness. Those remain future work in the approved roadmap.

## Actual new Customer vote on S2-R2

Customer /root/customer votes FOR exact council-s2-release-proposal-02.md raw SHA256 `FAB3BF5228599D0C22F4024912258F61626CF9D5416A0F93349435F1B1F86C98`, independently recomputed after reading full proposal. This is a new vote, not a transferred S2-P1 or prior-candidate vote. Source `d0784e2766f5af875225e62f85aa11f85ccce5d9`, EXE `E2189EA8C463E7E3E146EF7983608A95F474B2FFA35FA02555F8A0CF3E47986E`, ZIP `E075D999D03729CFC453CCE67BC1400F9413AD7111B750FE873F998D5B47A739`.

Read exact sprint-02-qa-d0784e.md and sprint-02-qa-package11.json in full. Independent QA explicitly closes A12 with fresh native WindowsPS5 cold PostgreSQL initialization, stock child environment, current-user protected DACL/nonadmin token,1635manifest files/0mismatches, actual public package browser20/roles5/UI3 and restart37824→820/after4, matching both live EXE identities. Actual source11 A01–A11 checks were repeated; final user installation starts at the first-account form without QA users. This meets the customer usability/delivery barrier previously withheld. These are independent QA-attributed proofs, not Customer-executed operations.

Customer scope judgement: selected A01–A12 are valuable and supported; minor Apply Draft→Save and password-byte wording are accepted follow-ups. Historical failed packages, missing overwritten raw stderr and bounded coverage remain explicit. No full-stage/enterprise/oracle or CI PostgreSQL parity claim is accepted. The allowed non-runtime health smoke mode adjustment does not create an assumed CI PASS; actual post-push status must be reported.

This vote does not bypass independent TechnicalDebt's actual COLD01 final closure or any mandatory STOP, nor majority. Latest TD snapshot read still described final package gate as pending; that reviewer must issue its own updated conclusion from the new evidence. Human final acceptance is not impersonated. No runtime/global-UI changes by Customer.
