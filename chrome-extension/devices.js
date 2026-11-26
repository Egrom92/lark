// Список колонок и наушников. Chrome называет устройства только страницам расширения с разрешением на микрофон;
// видимые страницы (настройка, окно значка) сохраняют список в хранилище — им пользуются меню и невидимый документ.
async function larkDevices() {
  const all = await navigator.mediaDevices.enumerateDevices();
  return all
    .filter((d) => d.kind === 'audiooutput' && d.label && d.deviceId && d.deviceId !== 'default' && d.deviceId !== 'communications')
    .map((d) => ({ deviceId: d.deviceId, label: d.label.replace(/\s*\((Built-in|Bluetooth|Virtual)\)\s*$/i, '') }));
}
async function larkSaveDevices() {
  const list = await larkDevices();
  if (list.length) {
    await chrome.storage.local.set({ devices: list });
    chrome.runtime.sendMessage({ type: 'devicesChanged' });
  }
  return list;
}
