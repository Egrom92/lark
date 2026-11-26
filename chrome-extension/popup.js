// Значок расширения: куда выводить звук текущей вкладки. Нажатие на значок — то самое действие пользователя,
// после которого Chrome разрешает забрать звук вкладки.
const t = (k) => chrome.i18n.getMessage(k) || k;
document.getElementById('title').textContent = t('popupTitle');
const hint = document.getElementById('hint');
const list = document.getElementById('list');

function item(label, on, click) {
  const li = document.createElement('li');
  const b = document.createElement('button');
  b.textContent = label;
  if (on) { b.className = 'on'; b.append(document.createTextNode('✓')); }
  b.onclick = click;
  li.append(b);
  list.append(li);
}

(async () => {
  try { await larkSaveDevices(); } catch (e) {}
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const st = await chrome.runtime.sendMessage({ type: 'state', tabId: tab.id });
  const pick = async (deviceId, label) => {
    const res = await chrome.runtime.sendMessage({ type: 'route', tabId: tab.id, deviceId, label });
    if (res && res.ok) window.close();
    else { hint.className = 'err'; hint.textContent = (res && res.error) || t('cantCapture'); }
  };
  item(t('sameAsAll'), st.current === 'default', () => pick('default', ''));
  for (const d of st.devices) item(d.label, st.current === d.deviceId, () => pick(d.deviceId, d.label));
  if (!st.devices.length) {
    hint.textContent = t('noDevices') + ' ';
    const a = document.createElement('a');
    a.href = '#'; a.textContent = t('allowDevices');
    a.onclick = () => chrome.tabs.create({ url: 'setup.html' });
    hint.append(a);
  } else {
    hint.textContent = t('popupHint');
  }
})();
