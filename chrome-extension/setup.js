// Один раз: разрешение на микрофон для расширения — иначе Chrome не называет колонки и наушники.
// Микрофон сразу отпускается, ничего не записывается.
const t = (k) => chrome.i18n.getMessage(k) || k;
document.getElementById('title').textContent = t('setupTitle');
document.getElementById('text').textContent = t('setupText');
const btn = document.getElementById('allow');
const msg = document.getElementById('msg');
btn.textContent = t('setupButton');
btn.onclick = async () => {
  try {
    const s = await navigator.mediaDevices.getUserMedia({ audio: true });
    s.getTracks().forEach((tr) => tr.stop());
    await chrome.runtime.sendMessage({ type: 'permissionGranted' });
    msg.textContent = t('setupDone');
    btn.hidden = true;
  } catch (e) {
    msg.textContent = t('setupFailed');
  }
};
