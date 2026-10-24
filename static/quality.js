/* Clear a previous preview before every request, including failed requests. */
(() => {
  'use strict';
  async function runQuality(action, doc = document) {
    const panel = doc.getElementById('quality-result');
    if (!panel) return;
    panel.textContent = 'Считаем новую оценку… Предыдущий результат больше не показан.';
    const pending = panel.textContent;
    const failed = 'Оценка не получена. Проверьте подключение и права проекта, затем повторите расчёт.';
    try {
      await action();
      // Datastar can resolve a failed HTTP request without applying a patch.
      // A completed request must not leave the original pending panel behind.
      const current = doc.getElementById('quality-result');
      if (current === panel && current.textContent === pending) current.textContent = failed;
    } catch {
      const current = doc.getElementById('quality-result');
      if (current) current.textContent = failed;
    }
  }
  if (typeof window !== 'undefined') window.piRunQuality = runQuality;
  if (typeof module !== 'undefined' && module.exports) module.exports = {runQuality};
})();
