import { clock, dateLabel, deleteRecording, getRecording, listRecordings, updateRecording } from './lib/db.js';
import { exportRecording, keyframeAtOrAfter, needsReencode } from './lib/ffmpeg.js';
import { safeName } from './lib/names.js';

const $ = (id) => document.getElementById(id);
const video = $('video');
let current = null; // the open recording (with its blob)
let url = null;
let duration = 0;
let trim = { start: 0, end: 0 };
let saveTimer = null;
let busy = false;

// ---- library ---------------------------------------------------------------------

async function renderList() {
  const items = await listRecordings();
  $('count').textContent = items.length ? `${items.length}` : '';
  const list = $('list');
  list.replaceChildren();
  if (!items.length) {
    list.innerHTML = '<p class="empty">No recordings yet.</p>';
    return items;
  }
  for (const r of items) {
    const row = document.createElement('div');
    row.className = `item${current?.id === r.id ? ' sel' : ''}`;
    row.tabIndex = 0;
    row.dataset.id = r.id;
    const img = r.thumb ? Object.assign(document.createElement('img'), { src: r.thumb, alt: '' }) : Object.assign(document.createElement('div'), { className: 'ph' });
    const text = document.createElement('div');
    const b = document.createElement('b');
    b.textContent = r.title || dateLabel(r.createdAt);
    const meta = document.createElement('small');
    const tag = document.createElement('span');
    const done = (r.exported || []).length > 0;
    tag.className = `tag ${done ? 'done' : 'draft'}`;
    tag.textContent = done ? 'Downloaded' : 'Draft';
    meta.append(document.createTextNode(`${clock((r.durationMs || 0) / 1000)} · ${r.title ? dateLabel(r.createdAt) : sizeLabel(r.size)}`), tag);
    text.append(b, meta);
    row.append(img, text);
    const open = () => { location.hash = r.id; };
    row.addEventListener('click', open);
    row.addEventListener('keydown', (e) => { if (e.key === 'Enter') open(); });
    list.append(row);
  }
  return items;
}

const sizeLabel = (bytes = 0) => (bytes > 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(bytes / 1e6))} MB`);

// ---- open a recording ------------------------------------------------------------------

async function open(id) {
  if (!id) {
    current = null;
    $('editor').hidden = true;
    $('none').hidden = false;
    return;
  }
  const rec = await getRecording(id);
  if (!rec) {
    location.hash = '';
    return;
  }
  current = rec;
  if (url) URL.revokeObjectURL(url);
  url = URL.createObjectURL(rec.blob);
  $('none').hidden = true;
  $('editor').hidden = false;
  $('title').value = rec.title || `Recording · ${dateLabel(rec.createdAt)}`;
  $('format').value = 'mp4';
  setMessage('');
  renderStatus();
  const { stoppedAtLimit } = await chrome.storage.local.get('stoppedAtLimit');
  $('limit').hidden = stoppedAtLimit !== rec.id;
  duration = (rec.durationMs || 0) / 1000;
  trim = { start: rec.trimStart ?? 0, end: rec.trimEnd ?? duration };
  video.src = url;
  video.load();
  for (const el of $('list').children) el.classList.toggle('sel', el.dataset.id === id);
  layout();
}

video.addEventListener('loadedmetadata', () => {
  if (Number.isFinite(video.duration) && video.duration > 0) {
    const fresh = video.duration;
    if (Math.abs(fresh - duration) > 0.25) {
      const wasWhole = Math.abs(trim.end - duration) < 0.05;
      duration = fresh;
      if (wasWhole || trim.end > duration) trim.end = duration;
    }
  }
  trim.start = Math.min(trim.start, Math.max(0, trim.end - 0.5));
  video.currentTime = Math.min(trim.start + 0.01, duration);
  layout();
});

function renderStatus() {
  const done = (current?.exported || []).length > 0;
  $('status').className = `tag ${done ? 'done' : 'draft'}`;
  $('status').textContent = done ? 'Downloaded' : 'Draft';
  $('show').hidden = !done;
}

// ---- playback (the big button, the video, and Space) -----------------------------------

function play() {
  if (!current) return;
  if (video.currentTime < trim.start || video.currentTime >= trim.end - 0.05) video.currentTime = trim.start;
  video.play().catch(() => setMessage('This recording could not be played here. Try downloading it.', 'err'));
}
function togglePlay() { if (video.paused) play(); else video.pause(); }

$('big').addEventListener('click', play);
video.addEventListener('click', togglePlay);
$('play').addEventListener('click', togglePlay);
video.addEventListener('play', () => { $('big').hidden = true; $('play').textContent = '❚❚ Pause'; });
video.addEventListener('pause', () => { $('big').hidden = false; $('play').textContent = '▶ Play'; });
video.addEventListener('timeupdate', () => {
  if (!video.paused && video.currentTime >= trim.end) {
    video.pause();
    video.currentTime = trim.end;
  }
  layout();
});
document.addEventListener('keydown', (e) => {
  if (e.code === 'Space' && e.target === document.body) { e.preventDefault(); togglePlay(); }
});

// ---- trim --------------------------------------------------------------------------

function layout() {
  const d = duration || 1;
  const pct = (t) => `${(Math.max(0, Math.min(d, t)) / d) * 100}%`;
  $('h-start').style.left = pct(trim.start);
  $('h-end').style.left = pct(trim.end);
  $('kept').style.left = pct(trim.start);
  $('kept').style.width = `${((trim.end - trim.start) / d) * 100}%`;
  $('playhead').style.left = pct(video.currentTime || 0);
  $('t-start').textContent = '0:00';
  $('t-end').textContent = clock(duration);
  const whole = trim.start < 0.05 && trim.end > duration - 0.05;
  $('t-kept').textContent = whole
    ? `Whole recording · ${clock(duration)}`
    : `Keeps ${clock(trim.start)}–${clock(trim.end)} · ${clock(trim.end - trim.start)} of ${clock(duration)}`;
  for (const [id, value] of [['h-start', trim.start], ['h-end', trim.end]]) {
    $(id).setAttribute('aria-valuenow', value.toFixed(1));
    $(id).setAttribute('aria-valuetext', clock(value));
  }
}

function setTrim(next) {
  const min = Math.min(0.5, duration);
  let start = next.start ?? trim.start;
  // A fast trim starts on a keyframe (about every second): the handle shows
  // exactly where the download will begin.
  if (next.start != null && next.snap !== false && current && !needsReencode(current.codec, $('format').value, current.mime)) {
    start = start < 0.05 ? 0 : keyframeAtOrAfter(current.keyframes, start);
  }
  trim.start = Math.max(0, Math.min(start, duration - min));
  trim.end = Math.min(duration, Math.max(next.end ?? trim.end, trim.start + min));
  layout();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    if (!current) return;
    const whole = trim.start < 0.05 && trim.end > duration - 0.05;
    updateRecording(current.id, { trimStart: whole ? null : trim.start, trimEnd: whole ? null : trim.end });
  }, 400);
}

const timeAt = (clientX) => {
  const r = $('track').getBoundingClientRect();
  return ((clientX - r.left) / r.width) * duration;
};

for (const [id, key] of [['h-start', 'start'], ['h-end', 'end']]) {
  const h = $(id);
  h.addEventListener('pointerdown', (e) => {
    e.stopPropagation();
    h.setPointerCapture(e.pointerId);
    const move = (ev) => {
      setTrim({ [key]: timeAt(ev.clientX), snap: false });
      video.currentTime = trim[key];
    };
    const up = () => {
      h.removeEventListener('pointermove', move);
      h.removeEventListener('pointerup', up);
      if (key === 'start') { setTrim({ start: trim.start }); video.currentTime = trim.start; }
    };
    h.addEventListener('pointermove', move);
    h.addEventListener('pointerup', up);
  });
  h.addEventListener('keydown', (e) => {
    const step = e.shiftKey ? 1 : 0.1;
    if (e.key === 'ArrowLeft') setTrim({ [key]: trim[key] - step });
    if (e.key === 'ArrowRight') setTrim({ [key]: trim[key] + step });
  });
}
$('track').addEventListener('pointerdown', (e) => {
  video.currentTime = Math.max(0, Math.min(duration, timeAt(e.clientX)));
  layout();
});
$('set-start').addEventListener('click', () => setTrim({ start: video.currentTime }));
$('set-end').addEventListener('click', () => setTrim({ end: video.currentTime }));
$('reset').addEventListener('click', () => setTrim({ start: 0, end: duration }));

// ---- name, delete, download ------------------------------------------------------------

$('title').addEventListener('change', async () => {
  if (!current) return;
  const title = $('title').value.trim();
  await updateRecording(current.id, { title: title || null });
  current.title = title || null;
  renderList();
});

$('delete').addEventListener('click', async () => {
  if (!current) return;
  const done = (current.exported || []).length > 0;
  // eslint-disable-next-line no-alert
  if (!confirm(done ? 'Delete this recording? Files you downloaded are kept.' : 'Delete this recording? It hasn\'t been downloaded, so it will be gone for good.')) return;
  const id = current.id;
  video.removeAttribute('src');
  video.load();
  await deleteRecording(id);
  const items = await renderList();
  location.hash = items[0]?.id || '';
});

function setMessage(text, kind = '') {
  $('msg').textContent = text;
  $('msg').className = `msg ${kind}`;
}

function progress(value) {
  $('progress').hidden = value == null;
  $('progress').firstElementChild.style.width = `${Math.round((value || 0) * 100)}%`;
}



$('download').addEventListener('click', async () => {
  if (!current || busy) return;
  busy = true;
  $('download').disabled = true;
  video.pause();
  const format = $('format').value;
  const trimmed = trim.start > 0.05 || trim.end < duration - 0.05;
  const converting = needsReencode(current.codec, format, current.mime);
  setMessage(converting ? 'Converting… this can take about as long as the video.' : trimmed ? 'Trimming…' : 'Preparing your file…');
  progress(0);
  try {
    const out = await exportRecording(current.blob, current.mime, {
      start: trimmed ? trim.start : null,
      end: trimmed ? trim.end : null,
      format,
      duration,
      codec: current.codec,
    }, progress);
    const fileUrl = URL.createObjectURL(out);
    const downloadId = await chrome.downloads.download({
      url: fileUrl,
      filename: `Screen Recorder/${safeName($('title').value)}.${format}`,
      conflictAction: 'uniquify',
    });
    setTimeout(() => URL.revokeObjectURL(fileUrl), 120_000);
    const exported = [...(current.exported || []), { downloadId, at: Date.now(), format }];
    current = { ...current, exported };
    await updateRecording(current.id, { exported });
    renderStatus();
    renderList();
    setMessage('Saved to your Downloads folder (Screen Recorder). The recording stays here too, so you can download it again.', 'ok');
  } catch (error) {
    console.error(error);
    setMessage(`Download failed: ${error?.message || error}. Try again, or choose the other file type.`, 'err');
  } finally {
    progress(null);
    busy = false;
    $('download').disabled = false;
  }
});

$('show').addEventListener('click', () => {
  const last = (current?.exported || []).at(-1);
  if (last?.downloadId != null) chrome.downloads.show(last.downloadId);
});
$('upgrade').addEventListener('click', () => chrome.tabs.create({ url: 'upgrade.html' }));

chrome.runtime.onMessage.addListener((msg) => {
  if (msg?.type === 'recordings-changed') renderList();
});
addEventListener('hashchange', () => open(decodeURIComponent(location.hash.slice(1))));

(async () => {
  const items = await renderList();
  const id = decodeURIComponent(location.hash.slice(1)) || items[0]?.id;
  if (id && !location.hash) location.hash = id;
  else open(id);
})();
