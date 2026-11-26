// Метки для Lark: на странице работает «Lark для Chrome» (data-lark-ext) и куда выведен звук вкладки (data-lark-sink).
(() => {
  const root = document.documentElement;
  const setSink = (label) => (label ? root.setAttribute('data-lark-sink', label) : root.removeAttribute('data-lark-sink'));
  root.setAttribute('data-lark-ext', '1');
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg && msg.type === 'lark-sink') setSink(msg.label);
  });
  chrome.runtime.sendMessage({ type: 'mySink' }, (res) => {
    if (chrome.runtime.lastError) return;
    setSink(res && res.label);
  });
})();
