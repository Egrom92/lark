// Lark для Chrome: звук одной вкладки — в выбранное устройство.
// Chrome отдаёт звук вкладки расширению только после действия пользователя на этой вкладке (значок расширения,
// пункт меню правой кнопки). Звук забирает и проигрывает в нужное устройство невидимый документ offscreen.html.
// Куда выведена вкладка, расширение пишет в атрибут страницы data-lark-sink — его читает Lark и показывает «→ JBL».

const t = (k) => chrome.i18n.getMessage(k) || k;
const MENU = 'lark';
const SAME = 'lark:default';
const ALLOW = 'lark:allow';

// --- Невидимый документ, который держит захваченный звук вкладок

let creating = null;
async function ensureOffscreen() {
  const url = chrome.runtime.getURL('offscreen.html');
  const have = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'], documentUrls: [url] });
  if (have.length) return;
  if (!creating) {
    creating = chrome.offscreen
      .createDocument({ url: 'offscreen.html', reasons: ['USER_MEDIA'], justification: 'Play a tab’s sound on the output device the user chose.' })
      .finally(() => (creating = null));
  }
  await creating;
}

async function offscreen(msg) {
  await ensureOffscreen();
  return chrome.runtime.sendMessage({ ...msg, target: 'offscreen' });
}

// --- Куда выведены вкладки: tabId → { deviceId, label }

async function routes() {
  return (await chrome.storage.session.get('routes')).routes || {};
}
async function saveRoutes(r) {
  await chrome.storage.session.set({ routes: r });
}

async function tellPage(tabId, label) {
  try {
    await chrome.tabs.sendMessage(tabId, { type: 'lark-sink', label: label || '' });
  } catch (e) {
    /* на странице нет content.js (служебная страница) — не важно */
  }
}

/** Вывести звук вкладки в устройство; deviceId 'default' — вернуть как у всех. */
async function route(tabId, deviceId, label) {
  const r = await routes();
  if (deviceId === 'default') {
    await offscreen({ type: 'stop', tabId });
    delete r[tabId];
    await saveRoutes(r);
    await tellPage(tabId, '');
    return { ok: true };
  }
  const has = await offscreen({ type: 'has', tabId });
  if (has && has.has) {
    const res = await offscreen({ type: 'sink', tabId, deviceId });
    if (!res || !res.ok) return res || { ok: false };
  } else {
    let streamId;
    try {
      streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
    } catch (e) {
      return { ok: false, error: t('cantCapture') + ' ' + (e && e.message ? e.message : '') };
    }
    const res = await offscreen({ type: 'start', tabId, streamId, deviceId });
    if (!res || !res.ok) return res || { ok: false };
  }
  r[tabId] = { deviceId, label };
  await saveRoutes(r);
  await tellPage(tabId, label);
  return { ok: true };
}

// --- Меню правой кнопки: «Lark: звук этой вкладки» → устройства

async function devices() {
  const res = await offscreen({ type: 'devices' });
  return (res && res.devices) || [];
}

const mk = (o) => chrome.contextMenus.create({ contexts: ['all'], ...o }, () => void chrome.runtime.lastError);

// Меню собирается по очереди: два одновременных вызова дали бы повторяющиеся пункты.
let menuQueue = Promise.resolve();
function buildMenu() {
  menuQueue = menuQueue.then(async () => {
    const list = await devices();
    await chrome.contextMenus.removeAll();
    mk({ id: MENU, title: t('menuTitle') });
    mk({ id: SAME, parentId: MENU, title: t('sameAsAll') });
    if (!list.length) return mk({ id: ALLOW, parentId: MENU, title: t('allowDevices') });
    mk({ id: 'lark:sep', parentId: MENU, type: 'separator' });
    for (const d of list) mk({ id: 'lark:dev:' + d.deviceId, parentId: MENU, title: d.label });
  }).catch(() => {});
  return menuQueue;
}

chrome.runtime.onInstalled.addListener(() => {
  buildMenu();
  // Без разрешения Chrome не называет устройства — сразу показать страницу настройки.
  devices().then((l) => {
    if (!l.length) chrome.tabs.create({ url: 'setup.html' });
  });
});
chrome.runtime.onStartup.addListener(buildMenu);

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab || tab.id === undefined) return;
  if (info.menuItemId === ALLOW) return chrome.tabs.create({ url: 'setup.html' });
  if (info.menuItemId === SAME) return route(tab.id, 'default', '');
  const id = String(info.menuItemId);
  if (!id.startsWith('lark:dev:')) return;
  const deviceId = id.slice('lark:dev:'.length);
  const d = (await devices()).find((x) => x.deviceId === deviceId);
  route(tab.id, deviceId, d ? d.label : '');
});

// --- Сообщения: popup, страницы и offscreen

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg.target === 'offscreen') return false;
  (async () => {
    if (msg.type === 'route') return reply(await route(msg.tabId, msg.deviceId, msg.label));
    if (msg.type === 'state') {
      const r = await routes();
      return reply({ devices: await devices(), current: r[msg.tabId] ? r[msg.tabId].deviceId : 'default' });
    }
    if (msg.type === 'mySink') {   // content.js после загрузки страницы: куда выведена эта вкладка
      const r = sender.tab ? (await routes())[sender.tab.id] : null;
      return reply({ label: r ? r.label : '' });
    }
    if (msg.type === 'devicesChanged' || msg.type === 'permissionGranted') {
      await buildMenu();
      return reply({ ok: true });
    }
    if (msg.type === 'ended') {   // вкладку закрыли или захват прервался
      const r = await routes();
      delete r[msg.tabId];
      await saveRoutes(r);
      return reply({ ok: true });
    }
    reply({ ok: false });
  })();
  return true;
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const r = await routes();
  if (r[tabId]) {
    delete r[tabId];
    await saveRoutes(r);
    offscreen({ type: 'stop', tabId });
  }
});
