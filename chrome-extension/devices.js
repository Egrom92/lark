// Список колонок и наушников. Chrome называет устройства только страницам расширения с разрешением на микрофон;
// видимые страницы (настройка, окно значка) сохраняют список в хранилище — им пользуются меню и невидимый документ.
// Chrome дописывает к названию способ подключения: «JBL Flip 6 (Bluetooth)», «LG HDR 4K (DisplayPort)»,
// а у USB — код производителя: «Scarlett 2i2 (1235:8210)». Lark знает устройства без этого хвоста.
function larkCleanLabel(label) {
  return label.replace(/\s*\((Built-in|Bluetooth( LE)?|Virtual|Aggregate|AirPlay|DisplayPort|HDMI|Thunderbolt|FireWire|USB|PCI|AVB|[0-9a-f]{4}:[0-9a-f]{4})\)\s*$/i, '');
}
async function larkDevices() {
  const all = await navigator.mediaDevices.enumerateDevices();
  return all
    .filter((d) => d.kind === 'audiooutput' && d.label && d.deviceId && d.deviceId !== 'default' && d.deviceId !== 'communications')
    .map((d) => ({ deviceId: d.deviceId, label: larkCleanLabel(d.label) }));
}
async function larkSaveDevices() {
  const list = await larkDevices();
  if (list.length) {
    await chrome.storage.local.set({ devices: list });
    chrome.runtime.sendMessage({ type: 'devicesChanged' });
  }
  return list;
}
