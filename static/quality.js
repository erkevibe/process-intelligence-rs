/* Clear a previous preview before every request, including failed requests. */
(() => {
  'use strict';
  async function runQuality(action, doc = document) {
    const panel = doc.getElementById('quality-result');
    if (!panel) return;
    panel.textContent = 'Считаем новую оценку… Предыдущий результат больше не показан.';
    try {
      await action();
    } catch {
      const current = doc.getElementById('quality-result');
      if (current) current.textContent = 'Оценка не получена. Проверьте подключение и права проекта, затем повторите расчёт.';
    }
  }
  if (typeof window !== 'undefined') window.piRunQuality = runQuality;
  if (typeof module !== 'undefined' && module.exports) module.exports = {runQuality};
})();
