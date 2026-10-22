/* A bounded rendering island: the server owns authorization and job state. */
(() => {
  'use strict';
  const MAX_REVISION = 18446744073709551615n;
  const JOB_ID = /^job-[0-9]{1,32}$/;
  const TRANSPORT_PREFIX = 'conversion-transport-';
  let observer = null;

  function parseRevision(value) {
    if (typeof value !== 'string' || value.trim() !== value || !/^(0|[1-9][0-9]{0,19})$/.test(value)) return null;
    const revision = BigInt(value);
    return revision <= MAX_REVISION ? revision : null;
  }
  function shouldApplyRevision(current, incoming) {
    const before = parseRevision(current);
    const after = parseRevision(incoming);
    return before !== null && after !== null && after > before;
  }
  function applyTransport(transport, doc) {
    if (!transport || typeof transport.id !== 'string' || !transport.id.startsWith(TRANSPORT_PREFIX)) return false;
    const jobId = transport.id.slice(TRANSPORT_PREFIX.length);
    if (jobId.trim() !== jobId || !JOB_ID.test(jobId)) return false;
    const templates = Array.from(transport.children).filter(node => node.tagName === 'TEMPLATE' && node.hasAttribute('data-conversion-update'));
    if (!templates.length) return false;
    const uniqueEnvelope = transport.children.length === 1 && templates.length === 1;
    let applied = false;
    for (const template of templates) {
      try {
        if (!uniqueEnvelope || template.dataset.jobId !== jobId || !template.content || template.content.children.length !== 1) continue;
        // Non-whitespace siblings inside the inert envelope are not a panel.
        if (Array.from(template.content.childNodes).some(node => node.nodeType !== 1 && (node.nodeType !== 3 || node.textContent.trim() !== ''))) continue;
        const candidate = template.content.firstElementChild;
        const panelId = `conversion-${jobId}`;
        if (candidate.tagName !== 'ARTICLE' || candidate.id !== panelId) continue;
        const current = doc.getElementById(panelId);
        if (!current || current.tagName !== 'ARTICLE' || transport.contains(current) || doc.querySelectorAll(`[id="${panelId}"]`).length !== 1) continue;
        // The candidate may not smuggle a second copy of the panel's own ID.
        if (candidate.querySelector(`[id="${panelId}"]`)) continue;
        if (!shouldApplyRevision(current.getAttribute('data-revision'), candidate.getAttribute('data-revision'))) continue;
        current.replaceWith(candidate.cloneNode(true));
        applied = true;
      } finally {
        // Clear both accepted and rejected envelopes. Reconnect may deliver the
        // same revision again, which must never change the visible panel.
        template.remove();
      }
    }
    return applied;
  }
  function start(doc) {
    if (observer || !doc || !doc.documentElement) return;
    const Observer = doc.defaultView && doc.defaultView.MutationObserver;
    if (!Observer) return;
    const scan = () => {
      // The product retains at most eight tasks per project. Only conversion
      // envelopes are inspected; the outer Datastar watcher is never replaced.
      for (const transport of doc.querySelectorAll('[id^="conversion-transport-job-"]')) applyTransport(transport, doc);
    };
    observer = new Observer(scan);
    observer.observe(doc.documentElement, {childList: true, subtree: true});
    scan();
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = {parseRevision, shouldApplyRevision, applyTransport, start};
  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => start(document), {once: true});
    else start(document);
  }
})();
