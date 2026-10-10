# Independent browser observation

Observer qa_process, app/UI not authored by observer. Existing Chrome executable, headless isolated context, bundled Playwright; no installs or user account/profile. Server after app-07 restart, commit not yet frozen.

QA-BROWSER-01 closed on active path: actual native multipart upload succeeds after same-origin Referrer-Policy; foreign origin rejection separately tested. Former null-origin403 evidence remains historical. In-process test RESUME is separate council P2 decision, not browser acceptance.

Current report .local/qa-browser/report.json SHA256 84AD7D70D2D55BF6218C2BA0F320A778AA7361F82813FD0683F2CA51338C9A08. Thirteen scoped assertions passed: actual CSP header, manual graph, SSE threshold with exact pan/zoom preservation, actual graph node click, rapid 1→3→2 changes, graph/export agreement, selection details/export agreement, actual edge click then hidden edge selection clearing, invalid upload retaining previous graph, HTML labels inert, no JavaScript page exceptions, classified console diagnostics, local network only.

Console contains expected422 from deliberate invalid upload and404 resource diagnostic (likely favicon; precise URL not captured in report). Thus this report does not claim absence of every runtime error. Detailed native POST headers/body stay in private report. SSE controls checked on current code; clean checkout, final published SHA, production performance and full AC11 remain independent acceptance work.

Screenshots manually inspected: manual-filtered.png shows expected4/10/3 counts, three variants and threshold2 two edges. Nodes partially clipped after deliberately zooming in; fit control available. Screenshots and report remain .local/qa-browser pending safe publication selection. Invalid upload performs full navigation and resets camera; only valid same-log SSE camera preservation is required and verified here.
