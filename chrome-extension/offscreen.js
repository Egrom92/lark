// Невидимый документ: забирает звук вкладок (getUserMedia с chromeMediaSource 'tab') и проигрывает каждый
// в своё устройство через AudioContext.setSinkId. Пока звук вкладки захвачен, Chrome сам его не играет.

const tabs = new Map(); // tabId → { stream, ctx, deviceId }

async function deviceList() {
  return larkDevices();
}

/** Что видит невидимый документ — для диагностики в Lark. */
async function diag() {
  let perm = '?';
  try { perm = (await navigator.permissions.query({ name: 'microphone' })).state; } catch (e) { perm = 'err'; }
  const all = await navigator.mediaDevices.enumerateDevices();
  const outs = all.filter((d) => d.kind === 'audiooutput');
  return `perm=${perm} outputs=${outs.length} named=${outs.filter((d) => d.label).length}`;
}

function stop(tabId) {
  const x = tabs.get(tabId);
  if (!x) return;
  x.stream.getTracks().forEach((tr) => tr.stop());
  x.ctx.close();
  tabs.delete(tabId);
}

async function start(tabId, streamId, deviceId) {
  stop(tabId);
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    video: false,
  });
  const ctx = new AudioContext({ latencyHint: 'playback' });
  try {
    await ctx.setSinkId(deviceId);
    ctx.createMediaStreamSource(stream).connect(ctx.destination);
    await ctx.resume();
  } catch (e) {
    // Устройства уже нет (выключили, пока было открыто меню): захваченный звук отпустить, иначе вкладка
    // замолчит до перезагрузки — Chrome сам её не играет, пока звук у расширения.
    stream.getTracks().forEach((tr) => tr.stop());
    ctx.close();
    throw e;
  }
  stream.getAudioTracks().forEach((tr) =>
    tr.addEventListener('ended', () => {
      stop(tabId);
      chrome.runtime.sendMessage({ type: 'ended', tabId });
    }),
  );
  tabs.set(tabId, { stream, ctx, deviceId });
}

/** Колонку выключили, пока в неё играла вкладка: вернуть вкладке обычный звук, а не оставлять её немой. */
async function dropLostDevices() {
  if (!tabs.size) return;
  const all = await navigator.mediaDevices.enumerateDevices();
  const ids = new Set(all.filter((d) => d.kind === 'audiooutput' && d.deviceId).map((d) => d.deviceId));
  if (!ids.size) return;   // Chrome не показал устройства вовсе — судить не по чему
  for (const [tabId, x] of [...tabs]) {
    if (ids.has(x.deviceId)) continue;
    stop(tabId);
    chrome.runtime.sendMessage({ type: 'ended', tabId });
  }
}

navigator.mediaDevices.addEventListener('devicechange', () => {
  chrome.runtime.sendMessage({ type: 'devicesChanged' });
  dropLostDevices().catch(() => {});
});

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg.target !== 'offscreen') return false;
  (async () => {
    try {
      if (msg.type === 'devices') return reply({ devices: await deviceList() });
      if (msg.type === 'diag') return reply({ text: await diag() });
      if (msg.type === 'has') return reply({ has: tabs.has(msg.tabId) });
      if (msg.type === 'stop') { stop(msg.tabId); return reply({ ok: true }); }
      if (msg.type === 'sink') {
        const x = tabs.get(msg.tabId);
        if (!x) return reply({ ok: false, error: 'not captured' });
        await x.ctx.setSinkId(msg.deviceId);
        x.deviceId = msg.deviceId;
        return reply({ ok: true });
      }
      if (msg.type === 'start') { await start(msg.tabId, msg.streamId, msg.deviceId); return reply({ ok: true }); }
      reply({ ok: false, error: 'unknown' });
    } catch (e) {
      reply({ ok: false, error: String((e && e.message) || e) });
    }
  })();
  return true;
});
