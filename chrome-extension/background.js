// Lark для Chrome: звук одной вкладки — в выбранное устройство.
// Chrome отдаёт звук вкладки расширению только после действия пользователя на этой вкладке (значок расширения,
// пункт меню правой кнопки). Звук забирает и проигрывает в нужное устройство невидимый документ offscreen.html.
// Куда выведена вкладка, расширение пишет в атрибут страницы data-lark-sink — его читает Lark и показывает «→ JBL».

const t = (k) => chrome.i18n.getMessage(k) || k;
const MENU = 'lark';
const SAME = 'lark:default';
const ALLOW = 'lark:allow';

// --- Журнал: последние 200 событий (chrome.storage.session — живёт, пока открыт Chrome). При ошибке
// хвост журнала уходит на страницу (data-lark-log), и Lark переписывает его в свой журнал.

const logLines = [];
function log(msg) {
  const d = new Date();
  const line = d.toTimeString().slice(0, 8) + '.' + String(d.getMilliseconds()).padStart(3, '0') + ' ' + msg;
  logLines.push(line);
  if (logLines.length > 200) logLines.shift();
  chrome.storage.session.set({ larkLog: logLines.slice(-200) }).catch(() => {});
}
const logTail = (n = 12) => logLines.slice(-n).join(' ⏎ ');
const errText = (e) => String((e && e.message) || e);

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
  // Только что созданный документ может ещё не слушать — тогда «Receiving end does not exist»: повторить.
  for (let i = 0; ; i++) {
    await ensureOffscreen();
    try {
      return await chrome.runtime.sendMessage({ ...msg, target: 'offscreen' });
    } catch (e) {
      if (i >= 5 || !/Receiving end|Could not establish/.test(String(e && e.message))) throw e;
      await new Promise((r) => setTimeout(r, 150));
    }
  }
}

// --- Куда выведены вкладки: tabId → { deviceId, label }
// Правда одна — живой захват в offscreen-документе. Запись без захвата (расширение перезагрузили, Chrome закрыл
// документ) — устаревшая: она удаляется, а метка на странице снимается, чтобы Lark и окно значка не врали.

async function routes() {
  return (await chrome.storage.session.get('routes')).routes || {};
}

/** Куда реально выведена вкладка сейчас (или null), с уборкой устаревшей записи. */
async function liveRoute(tabId) {
  const r = await routes();
  if (!r[tabId]) return null;
  let has = false;
  try { has = !!((await offscreen({ type: 'has', tabId })) || {}).has; } catch (e) {}
  if (has) return r[tabId];
  delete r[tabId];
  await saveRoutes(r);
  await tellPage(tabId, '');
  return null;
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
  log(`route tab ${tabId} → ${deviceId === 'default' ? 'default' : label || deviceId.slice(0, 8)}`);
  const res = await routeInner(tabId, deviceId, label).catch((e) => ({ ok: false, error: 'exception: ' + errText(e) }));
  log(res.ok ? `route tab ${tabId}: ok` : `route tab ${tabId}: FAILED ${res.error}`);
  return res.ok ? res : { ...res, log: logTail() };
}

async function routeInner(tabId, deviceId, label) {
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
    log(`tab ${tabId} already captured — changing device`);
    const res = await offscreen({ type: 'sink', tabId, deviceId });
    if (!res || !res.ok) { lastError = 'sink: ' + ((res && res.error) || 'no answer'); return { ok: false, error: lastError }; }
  } else {
    let streamId;
    try {
      streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
      log(`tab ${tabId}: got stream id`);
    } catch (e) {
      lastError = 'capture: ' + errText(e);
      return { ok: false, error: lastError };
    }
    const res = await offscreen({ type: 'start', tabId, streamId, deviceId });
    if (!res || !res.ok) { lastError = 'start: ' + ((res && res.error) || 'no answer'); return { ok: false, error: lastError }; }
    lastError = '';
  }
  r[tabId] = { deviceId, label };
  await saveRoutes(r);
  await tellPage(tabId, label);
  return { ok: true };
}

// --- Меню правой кнопки: «Lark: звук этой вкладки» → устройства

let lastError = '';

/** Устройства: что видит невидимый документ, а если он без названий — список, сохранённый видимой страницей. */
async function devices() {
  let list = [];
  try {
    const res = await offscreen({ type: 'devices' });
    list = (res && res.devices) || [];
  } catch (e) { lastError = 'devices: ' + e.message; }
  if (list.length) {
    chrome.storage.local.set({ devices: list });
    return list;
  }
  return (await chrome.storage.local.get('devices')).devices || [];
}

/** Состояние для Lark (атрибут data-lark-diag на страницах): помогает понять, что не так. */
async function diagText() {
  let off = '';
  try { off = ((await offscreen({ type: 'diag' })) || {}).text || ''; } catch (e) { off = 'offscreen err ' + e.message; }
  const stored = ((await chrome.storage.local.get('devices')).devices || []).length;
  return `v${chrome.runtime.getManifest().version} ${off} stored=${stored}${lastError ? ' last=' + lastError : ''}`;
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

/** Подключиться к уже открытым вкладкам: Chrome сам ставит content.js только на страницы, загруженные после установки. */
async function injectIntoOpenTabs() {
  const all = await chrome.tabs.query({});
  for (const tab of all) {
    if (!tab.id || !/^https?:/.test(tab.url || '')) continue;
    chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['content.js'] }).catch(() => {});
  }
}

/** Захватов после запуска нет: старые записи убрать, метки со страниц снять. */
async function forgetAllRoutes() {
  const r = await routes();
  await saveRoutes({});
  for (const id of Object.keys(r)) await tellPage(Number(id), '');
}

chrome.runtime.onInstalled.addListener(async () => {
  await forgetAllRoutes();
  injectIntoOpenTabs();
  buildMenu();
  // Без разрешения Chrome не называет устройства — сразу показать страницу настройки.
  devices().then((l) => {
    if (!l.length) chrome.tabs.create({ url: 'setup.html' });
  });
});
chrome.runtime.onStartup.addListener(async () => { await forgetAllRoutes(); injectIntoOpenTabs(); buildMenu(); });

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab || tab.id === undefined) return;
  log(`context menu on tab ${tab.id}: ${info.menuItemId}`);
  const done = async (res) => {   // результат — на страницу: Lark покажет устройство или ошибку
    try { await chrome.tabs.sendMessage(tab.id, { type: 'lark-diag', diag: await diagText() }); } catch (e) {}
    return res;
  };
  if (info.menuItemId === ALLOW) return chrome.tabs.create({ url: 'setup.html' });
  if (info.menuItemId === SAME) return done(await route(tab.id, 'default', ''));
  const id = String(info.menuItemId);
  if (!id.startsWith('lark:dev:')) return;
  const deviceId = id.slice('lark:dev:'.length);
  const d = (await devices()).find((x) => x.deviceId === deviceId);
  done(await route(tab.id, deviceId, d ? d.label : ''));
});

// --- Сообщения: popup, страницы и offscreen

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg.target === 'offscreen') return false;
  (async () => {
    try { await handle(msg, sender, reply); } catch (e) {
      log(`message ${msg.type} crashed: ${errText(e)}`);
      reply({ ok: false, error: 'exception: ' + errText(e), log: logTail() });
    }
  })();
  return true;
});

async function handle(msg, sender, reply) {
  {
    if (msg.type === 'route') return reply(await route(msg.tabId, msg.deviceId, msg.label));
    if (msg.type === 'routeByLabel' && sender.tab) {   // просьба из Lark (через страницу): устройство по названию
      log(`Lark asks tab ${sender.tab.id} → ${msg.label}`);
      if (msg.label === 'default') return reply(await route(sender.tab.id, 'default', ''));
      const list = await devices();
      const d = list.find((x) => x.label === msg.label);
      if (!d) {
        log(`no device "${msg.label}" among: ${list.map((x) => x.label).join(', ') || 'none (no permission?)'}`);
        return reply({ ok: false, error: 'no device ' + msg.label, log: logTail() });
      }
      return reply(await route(sender.tab.id, d.deviceId, d.label));
    }
    if (msg.type === 'state') {
      const live = await liveRoute(msg.tabId);
      return reply({ devices: await devices(), current: live ? live.deviceId : 'default' });
    }
    if (msg.type === 'mySink') {   // content.js после загрузки страницы: куда выведена эта вкладка
      const live = sender.tab ? await liveRoute(sender.tab.id) : null;
      return reply({ label: live ? live.label : '' });   // диагностику — только после действия пользователя (меню)
    }
    if (msg.type === 'devicesChanged' || msg.type === 'permissionGranted') {
      await buildMenu();
      return reply({ ok: true });
    }
    if (msg.type === 'ended') {   // вкладку закрыли или захват прервался
      const r = await routes();
      delete r[msg.tabId];
      await saveRoutes(r);
      await tellPage(msg.tabId, '');
      return reply({ ok: true });
    }
    reply({ ok: false, error: 'unknown message ' + msg.type });
  }
}

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const r = await routes();
  if (r[tabId]) {
    delete r[tabId];
    await saveRoutes(r);
    offscreen({ type: 'stop', tabId }).catch(() => {});
  }
});
