// Coordinates a recording: gets the tab / window / screen from Chrome, hands
// it to the offscreen recorder, shows the on-page controls and effects, and
// opens the editor when it stops.
import { orphanChunkIds } from './lib/db.js';
import { recordingLimit } from './lib/pro.js';

const IDLE = { status: 'idle' };

async function getState() {
  const { rec } = await chrome.storage.session.get('rec');
  return rec || IDLE;
}

async function setState(rec) {
  await chrome.storage.session.set({ rec });
  await badge(rec);
  await broadcast(rec);
}

async function badge(rec) {
  const text = rec.status === 'recording' ? 'REC' : rec.status === 'paused' ? '❚❚' : rec.status === 'saving' ? '…' : '';
  await chrome.action.setBadgeText({ text });
  if (text) await chrome.action.setBadgeBackgroundColor({ color: rec.status === 'recording' ? '#E5483B' : '#6E6E73' });
}

/** Tells the on-page controls (and the popup, if open) what's happening. */
async function broadcast(rec) {
  chrome.runtime.sendMessage({ type: 'state', rec }).catch(() => {});
  for (const tabId of rec.overlayTabs || []) {
    chrome.tabs.sendMessage(tabId, { type: 'state', rec }).catch(() => {});
  }
}

// ---- offscreen recorder ------------------------------------------------------------

async function ensureOffscreen() {
  const contexts = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
  if (contexts.length) return;
  await chrome.offscreen.createDocument({
    url: 'offscreen.html',
    reasons: ['USER_MEDIA', 'DISPLAY_MEDIA'],
    justification: 'Records the tab, window or screen the user chose, with their microphone.',
  });
}

async function toOffscreen(msg) {
  await ensureOffscreen();
  const r = await chrome.runtime.sendMessage({ ...msg, target: 'offscreen' });
  if (!r?.ok) {
    throw Object.assign(new Error(r?.error || 'The recorder did not answer.'), {
      cancelled: Boolean(r?.cancelled), retryWithoutAudio: Boolean(r?.retryWithoutAudio),
    });
  }
  return r;
}

// ---- on-page controls and effects ---------------------------------------------------

const canInject = (url) => /^(https?|file):/.test(url || '') && !/^https:\/\/chrome(webstore)?\.google\.com\/webstore/.test(url || '');

async function inject(tabId) {
  try {
    const tab = await chrome.tabs.get(tabId);
    if (!canInject(tab.url)) return false;
    await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
    return true;
  } catch {
    return false;
  }
}

async function addOverlay(tabId) {
  const rec = await getState();
  if (rec.status !== 'recording' && rec.status !== 'paused') return;
  if (!(await inject(tabId))) return;
  const overlayTabs = [...new Set([...(rec.overlayTabs || []), tabId])];
  await setState({ ...rec, overlayTabs });
}

// Screen / window recordings: follow the user to whichever tab they open.
chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  const rec = await getState();
  if (rec.kind === 'display' && (rec.status === 'recording' || rec.status === 'paused')) addOverlay(tabId);
});
chrome.tabs.onUpdated.addListener(async (tabId, info) => {
  if (info.status !== 'complete') return;
  const rec = await getState();
  if ((rec.status === 'recording' || rec.status === 'paused') && (rec.overlayTabs || []).includes(tabId)) inject(tabId);
});

// ---- commands ----------------------------------------------------------------------

async function start({ source = 'tab', tabId, mic = true, camera = false, effects = true }) {
  const current = await getState();
  if (current.status === 'recording' || current.status === 'paused' || current.status === 'saving') {
    throw new Error('A recording is already running.');
  }
  if (!tabId) {
    const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    tabId = active?.id;
  }
  const limitSec = await recordingLimit();
  // A tab: Chrome hands it over directly. A window or screen: the recorder
  // page shows Chrome's "Choose what to share" prompt (Chrome doesn't let a
  // screen picked here be recorded there).
  let streamId = null;
  let kind = 'display';
  if (source === 'tab') {
    try {
      streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
      kind = 'tab';
    } catch (error) {
      // Chrome wouldn't hand the tab over (e.g. the extension wasn't clicked on
      // this tab): fall back to the share prompt, where the user picks it.
      console.warn('Tab capture unavailable; using the share prompt', error);
    }
  }
  const sourceAudio = kind === 'tab';
  const recId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  await chrome.storage.local.set({ lastOptions: { source, mic, camera, effects } });
  await setState({ status: 'starting', recId, kind, tabId, mic, camera, effects, limitSec, overlayTabs: [] });
  try {
    try {
      await toOffscreen({ type: 'start', recId, streamId, kind, mic, sourceAudio, limitSec, title: null, effects });
    } catch (error) {
      if (kind !== 'tab' || error.cancelled) throw error;
      // Recording the tab directly failed: let the user pick it in the share prompt.
      console.warn('Direct tab recording failed; using the share prompt', error);
      kind = 'display';
      await setState({ status: 'starting', recId, kind, tabId, mic, camera, effects, limitSec, overlayTabs: [] });
      await toOffscreen({ type: 'start', recId, streamId: null, kind, mic, sourceAudio: false, limitSec, title: null, effects });
    }
  } catch (error) {
    await setState(IDLE);
    throw error;
  }
  await setState({
    status: 'recording', recId, kind, tabId, mic, camera, effects, limitSec,
    startedAt: Date.now(), pausedAt: null, pausedTotal: 0, overlayTabs: [],
  });
  if (tabId) await addOverlay(tabId);
  return { ok: true };
}

async function pause() {
  const rec = await getState();
  if (rec.status !== 'recording') return;
  await toOffscreen({ type: 'pause' });
  await setState({ ...rec, status: 'paused', pausedAt: Date.now() });
}

async function resume() {
  const rec = await getState();
  if (rec.status !== 'paused') return;
  await toOffscreen({ type: 'resume' });
  await setState({ ...rec, status: 'recording', pausedTotal: (rec.pausedTotal || 0) + (Date.now() - rec.pausedAt), pausedAt: null });
}

async function stop({ discard = false } = {}) {
  const rec = await getState();
  if (rec.status !== 'recording' && rec.status !== 'paused') return;
  await setState({ ...rec, status: discard ? 'idle' : 'saving' });
  await toOffscreen({ type: discard ? 'discard' : 'stop' }).catch(async (error) => {
    await setState(IDLE);
    throw error;
  });
}

async function openEditor(recId) {
  const url = chrome.runtime.getURL(`editor.html${recId ? `#${recId}` : ''}`);
  const rec = await getState();
  let index;
  try {
    if (rec.tabId) index = (await chrome.tabs.get(rec.tabId)).index + 1;
  } catch { /* tab closed */ }
  await chrome.tabs.create({ url, index, active: true });
}

// ---- messages ----------------------------------------------------------------------

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg?.target === 'offscreen') return false;
  if (msg?.from === 'offscreen') {
    handleRecorderEvent(msg);
    return false;
  }
  const handlers = {
    start: () => start({ ...msg, tabId: msg.tabId }),
    pause, resume,
    stop: () => stop(),
    discard: () => stop({ discard: true }),
    state: getState,
    'open-editor': () => openEditor(msg.recId),
  };
  const fn = handlers[msg?.type];
  if (!fn) return false;
  Promise.resolve(fn()).then(
    (value) => reply({ ok: true, value }),
    (error) => reply({ ok: false, error: error?.message || String(error), cancelled: Boolean(error?.cancelled) }),
  );
  return true;
});

async function handleRecorderEvent(msg) {
  const rec = await getState();
  switch (msg.type) {
    case 'recorder-stopped': {
      const tabs = rec.overlayTabs || [];
      await setState(IDLE);
      for (const tabId of tabs) chrome.tabs.sendMessage(tabId, { type: 'state', rec: IDLE }).catch(() => {});
      if (!msg.discarded && msg.recId) await openEditor(msg.recId);
      break;
    }
    case 'recorder-saving':
      if (rec.status !== 'saving') await setState({ ...rec, status: 'saving' });
      break;
    case 'recorder-limit':
      await chrome.storage.local.set({ stoppedAtLimit: msg.recId || true });
      break;
    case 'recorder-error':
    case 'recorder-warning':
      await chrome.storage.session.set({ lastMessage: { text: msg.message, at: Date.now() } });
      chrome.runtime.sendMessage({ type: 'notice', text: msg.message }).catch(() => {});
      for (const tabId of rec.overlayTabs || []) chrome.tabs.sendMessage(tabId, { type: 'notice', text: msg.message }).catch(() => {});
      break;
    default:
  }
}

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== 'start-stop') return;
  const rec = await getState();
  if (rec.status === 'recording' || rec.status === 'paused') return stop();
  if (rec.status !== 'idle') return;
  const { lastOptions } = await chrome.storage.local.get('lastOptions');
  start({ ...(lastOptions || {}), source: 'tab' }).catch((error) => console.warn(error));
});

// Pieces left behind by a crash or a closed browser become a recording.
async function recoverOrphans() {
  const rec = await getState();
  if (rec.status !== 'idle') return;
  const ids = await orphanChunkIds().catch(() => []);
  if (!ids.length) return;
  await toOffscreen({ type: 'recover', ids }).catch((error) => console.warn('Recovery failed', error));
}

chrome.runtime.onStartup.addListener(() => { setState(IDLE).then(recoverOrphans); });
chrome.runtime.onInstalled.addListener(() => { getState().then((rec) => rec.status === 'idle' && recoverOrphans()); });
