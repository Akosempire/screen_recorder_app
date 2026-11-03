import { clock, dateLabel, listRecordings } from './lib/db.js';
import { isPro, license, plans, refreshLicense } from './lib/pro.js';

const $ = (id) => document.getElementById(id);
let source = 'tab';
let rec = { status: 'idle' };
let ticker = null;

const send = (type, extra = {}) => chrome.runtime.sendMessage({ type, ...extra });

function notice(text) {
  const n = $('notice');
  n.textContent = text || '';
  n.hidden = !text;
}

function setSource(s) {
  source = s;
  $('src-tab').setAttribute('aria-pressed', String(s === 'tab'));
  $('src-desktop').setAttribute('aria-pressed', String(s === 'desktop'));
  savePrefs();
}

function savePrefs() {
  chrome.storage.local.set({ lastOptions: { source, mic: $('mic').checked, camera: $('camera').checked, effects: $('effects').checked } });
}

function elapsed() {
  if (!rec.startedAt) return 0;
  return Math.max(0, ((rec.pausedAt || Date.now()) - rec.startedAt - (rec.pausedTotal || 0)) / 1000);
}

function render() {
  const live = rec.status === 'recording' || rec.status === 'paused';
  $('idle').hidden = live || rec.status === 'saving' || rec.status === 'starting';
  $('live').hidden = !live;
  $('saving').hidden = rec.status !== 'saving';
  $('live').classList.toggle('paused', rec.status === 'paused');
  $('pause').textContent = rec.status === 'paused' ? '▶ Resume' : '❚❚ Pause';
  $('live-what').textContent = rec.status === 'paused'
    ? 'Paused'
    : rec.kind === 'display' ? 'Recording your window or screen' : 'Recording this tab';
  clearInterval(ticker);
  if (live) {
    const tick = () => {
      const s = elapsed();
      $('clock').textContent = rec.limitSec ? `${clock(s)} / ${clock(rec.limitSec)}` : clock(s);
    };
    tick();
    ticker = setInterval(tick, 500);
  }
}

async function permissionState(name) {
  try {
    return (await navigator.permissions.query({ name })).state;
  } catch {
    return 'prompt';
  }
}

async function start() {
  notice('');
  const mic = $('mic').checked;
  const camera = $('camera').checked;
  savePrefs();
  // The popup can't show Chrome's permission prompt; a tab can.
  const needMic = mic && (await permissionState('microphone')) !== 'granted';
  const needCam = camera && (await permissionState('camera')) !== 'granted';
  if (needMic || needCam) {
    await chrome.tabs.create({ url: `permissions.html?mic=${needMic ? 1 : 0}&camera=${needCam ? 1 : 0}` });
    window.close();
    return;
  }
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  $('start').disabled = true;
  const r = await send('start', { source, tabId: tab?.id, mic, camera, effects: $('effects').checked });
  $('start').disabled = false;
  if (!r?.ok) {
    if (!r?.cancelled) notice(friendly(r?.error));
    return;
  }
  if (source === 'tab') window.close();
}

function friendly(error = '') {
  if (/Chrome pages cannot be captured|cannot be captured/i.test(error)) {
    return 'Chrome doesn\'t allow recording this page. Open a website tab, or choose "Window or screen".';
  }
  if (/activeTab|not been invoked/i.test(error)) {
    return 'Click the Screen Recorder button on the tab you want to record, then press Start.';
  }
  return error || 'Recording could not start. Try again.';
}

async function renderList() {
  const items = (await listRecordings()).slice(0, 3);
  const list = $('list');
  list.replaceChildren();
  if (!items.length) {
    const p = document.createElement('p');
    p.className = 'empty';
    p.textContent = 'Your recordings appear here. Each one is kept as a draft until you delete it.';
    list.append(p);
    return;
  }
  for (const r of items) {
    const row = document.createElement('div');
    row.className = 'item';
    row.tabIndex = 0;
    const img = r.thumb ? Object.assign(document.createElement('img'), { src: r.thumb, alt: '' }) : Object.assign(document.createElement('div'), { className: 'ph' });
    const text = document.createElement('div');
    const title = document.createElement('b');
    title.textContent = r.title || dateLabel(r.createdAt);
    const meta = document.createElement('small');
    meta.textContent = `${clock((r.durationMs || 0) / 1000)} · `;
    const tag = document.createElement('span');
    const exported = (r.exported || []).length > 0;
    tag.className = `tag ${exported ? 'done' : 'draft'}`;
    tag.textContent = exported ? 'Downloaded' : 'Draft';
    meta.append(tag);
    text.append(title, meta);
    row.append(img, text);
    const open = () => send('open-editor', { recId: r.id }).then(() => window.close());
    row.addEventListener('click', open);
    row.addEventListener('keydown', (e) => { if (e.key === 'Enter') open(); });
    list.append(row);
  }
}

async function renderPro() {
  const [p, l] = await Promise.all([plans(), license()]);
  const pro = isPro(l);
  const btn = $('pro');
  btn.hidden = !p.enabled && !pro;
  btn.textContent = pro ? 'Pro' : 'Upgrade';
  btn.classList.toggle('on', pro);
  const limit = $('limit');
  limit.hidden = !(p.enabled && !pro);
  limit.textContent = `Trial: recordings stop at ${clock(p.freeLimitSeconds)}. Pro removes the limit.`;
  refreshLicense().then((fresh) => { if (isPro(fresh) !== pro) renderPro(); });
}

async function init() {
  const { lastOptions } = await chrome.storage.local.get('lastOptions');
  if (lastOptions) {
    $('mic').checked = lastOptions.mic !== false;
    $('camera').checked = Boolean(lastOptions.camera);
    $('effects').checked = lastOptions.effects !== false;
    setSource(lastOptions.source === 'desktop' ? 'desktop' : 'tab');
  }
  const r = await send('state');
  rec = r?.value || { status: 'idle' };
  render();
  renderList();
  renderPro();
  const { lastMessage } = await chrome.storage.session.get('lastMessage');
  if (lastMessage && Date.now() - lastMessage.at < 60_000) notice(lastMessage.text);
}

$('src-tab').addEventListener('click', () => setSource('tab'));
$('src-desktop').addEventListener('click', () => setSource('desktop'));
for (const id of ['mic', 'camera', 'effects']) $(id).addEventListener('change', savePrefs);
$('start').addEventListener('click', start);
$('pause').addEventListener('click', () => send(rec.status === 'paused' ? 'resume' : 'pause'));
$('stop').addEventListener('click', () => send('stop'));
$('discard').addEventListener('click', () => {
  // eslint-disable-next-line no-alert
  if (confirm('Throw this recording away? It will not be saved.')) send('discard');
});
$('all').addEventListener('click', () => send('open-editor').then(() => window.close()));
$('pro').addEventListener('click', () => chrome.tabs.create({ url: 'upgrade.html' }).then(() => window.close()));

chrome.runtime.onMessage.addListener((msg) => {
  if (msg?.type === 'state') { rec = msg.rec; render(); }
  if (msg?.type === 'recordings-changed') renderList();
  if (msg?.type === 'notice') notice(msg.text);
});

init();
