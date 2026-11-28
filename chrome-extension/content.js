// Метки для Lark: на странице работает «Lark для Chrome» (data-lark-ext) и куда выведен звук вкладки (data-lark-sink).
// Атрибуты страницы видит и сам сайт, поэтому в data-lark-sink — не название устройства (в нём бывает имя владельца:
// «AirPods Pro (Roman)»), а короткий ключ от названия; Lark считает такой же ключ для своих устройств (sinkKey в Logic.swift).
(() => {
  // Уже подключён живой экземпляр — второй не нужен. После перезагрузки расширения старый экземпляр «мёртв»
  // (chrome.runtime.id пропадает) — тогда подключаемся заново.
  if (window.__larkAlive && window.__larkAlive()) return;
  window.__larkAlive = () => { try { return !!chrome.runtime.id; } catch (e) { return false; } };
  const root = document.documentElement;
  const key = (s) => {   // FNV-1a по единицам UTF-16
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0;
    return '#' + h.toString(16);
  };
  const setSink = (label) => (label ? root.setAttribute('data-lark-sink', key(label)) : root.removeAttribute('data-lark-sink'));
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
    let label;
    // Итог для Lark: data-lark-result = «ok» или «error: …»; при ошибке — ещё и последние строки журнала расширения.
    const fail = (why, log) => {
      root.setAttribute('data-lark-error', why);
      if (log) root.setAttribute('data-lark-log', log);
      root.setAttribute('data-lark-result', 'error: ' + why);
    };
    try { label = decodeURIComponent(want); } catch (e) { return fail('bad request'); }
    chrome.runtime.sendMessage({ type: 'routeByLabel', label }, (res) => {
      if (chrome.runtime.lastError) return fail('no reply from extension: ' + chrome.runtime.lastError.message);
      if (res && res.ok) {
        root.removeAttribute('data-lark-error');
        root.removeAttribute('data-lark-log');
        root.setAttribute('data-lark-result', 'ok');
      } else {
        fail((res && res.error) || ('empty answer ' + JSON.stringify(res)), res && res.log);
      }
    });
  };
  new MutationObserver(watch).observe(root, { attributes: true, attributeFilter: ['data-lark-want'] });
  chrome.runtime.sendMessage({ type: 'mySink' }, (res) => {
    if (chrome.runtime.lastError) return;
    setSink(res && res.label);
  });
})();
