// Метки для Lark: на странице работает «Lark для Chrome» (data-lark-ext) и куда выведен звук вкладки (data-lark-sink).
(() => {
  // Уже подключён живой экземпляр — второй не нужен. После перезагрузки расширения старый экземпляр «мёртв»
  // (chrome.runtime.id пропадает) — тогда подключаемся заново.
  if (window.__larkAlive && window.__larkAlive()) return;
  window.__larkAlive = () => { try { return !!chrome.runtime.id; } catch (e) { return false; } };
  const root = document.documentElement;
  const setSink = (label) => (label ? root.setAttribute('data-lark-sink', label) : root.removeAttribute('data-lark-sink'));
  root.setAttribute('data-lark-ext', '1');
  root.removeAttribute('data-lark-sink');   // старая метка от прошлого экземпляра — пока не подтвердит фон
  const setDiag = (d) => d && root.setAttribute('data-lark-diag', d);
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg && msg.type === 'lark-sink') setSink(msg.label);
    if (msg && msg.type === 'lark-diag') setDiag(msg.diag);
  });
  // Lark просит вывести вкладку в устройство: ставит на страницу data-lark-want (название устройства или default).
  // Chrome разрешает это без нового щелчка, если вкладка уже выводилась через расширение; иначе — ошибка в data-lark-error.
  const watch = () => {
    const want = root.getAttribute('data-lark-want');
    if (!want) return;
    root.removeAttribute('data-lark-want');
    chrome.runtime.sendMessage({ type: 'routeByLabel', label: decodeURIComponent(want) }, (res) => {
      if (chrome.runtime.lastError) return root.setAttribute('data-lark-error', chrome.runtime.lastError.message);
      if (res && res.ok) root.removeAttribute('data-lark-error');
      else root.setAttribute('data-lark-error', (res && res.error) || 'failed');
    });
  };
  new MutationObserver(watch).observe(root, { attributes: true, attributeFilter: ['data-lark-want'] });
  chrome.runtime.sendMessage({ type: 'mySink' }, (res) => {
    if (chrome.runtime.lastError) return;
    setSink(res && res.label);
    setDiag(res && res.diag);
  });
})();
