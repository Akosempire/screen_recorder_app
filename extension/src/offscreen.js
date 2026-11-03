// Runs in the extension's hidden offscreen page: turns a tab / window / screen
// stream id into a recording. Mixes the microphone with the tab or system
// sound, writes a piece to IndexedDB every second, and on stop joins them,
// fixes the file's length info (so it can be played and trimmed), and saves
// the recording.
import { deleteChunks, putChunk, putRecording, readChunks } from './lib/db.js';
import { finalizeRecording } from './lib/ffmpeg.js';

let session = null;

const send = (msg) => chrome.runtime.sendMessage({ ...msg, from: 'offscreen' }).catch(() => {});

/** MP4 (H.264) where Chrome can record it (Chrome 126+), WebM otherwise. */
export function pickMimeType(isSupported = (t) => MediaRecorder.isTypeSupported(t)) {
  const options = [
    'video/mp4;codecs=avc1.640028,mp4a.40.2',
    'video/mp4;codecs=avc1,mp4a.40.2',
    'video/mp4',
    'video/webm;codecs=vp9,opus',
    'video/webm;codecs=vp8,opus',
    'video/webm',
  ];
  return options.find((t) => isSupported(t)) || '';
}

async function captureStream(kind, streamId, wantSourceAudio) {
  const constraints = (withAudio) => ({
    audio: withAudio ? { mandatory: { chromeMediaSource: kind, chromeMediaSourceId: streamId } } : false,
    video: {
      mandatory: {
        chromeMediaSource: kind,
        chromeMediaSourceId: streamId,
        maxWidth: 3840,
        maxHeight: 2160,
        maxFrameRate: 30,
      },
    },
  });
  // A stream id works once; if this fails, the background falls back to the
  // share prompt.
  return navigator.mediaDevices.getUserMedia(constraints(wantSourceAudio));
}

/** Chrome's own "Choose what to share" prompt (a window or a whole screen). */
async function pickDisplay() {
  try {
    return await navigator.mediaDevices.getDisplayMedia({
      video: { frameRate: { ideal: 30, max: 30 }, width: { max: 3840 }, height: { max: 2160 } },
      audio: true,
      systemAudio: 'include',
      selfBrowserSurface: 'exclude',
      surfaceSwitching: 'include',
      monitorTypeSurfaces: 'include',
    });
  } catch (error) {
    if (error?.name === 'NotAllowedError' || error?.name === 'AbortError') {
      throw Object.assign(new Error('Nothing was chosen to share.'), { cancelled: true });
    }
    throw error;
  }
}

async function start({ recId, streamId, kind, mic, sourceAudio, limitSec, title, effects }) {
  if (session) throw new Error('Already recording.');
  const display = kind === 'display' ? await pickDisplay() : await captureStream(kind, streamId, sourceAudio);
  let micStream = null;
  if (mic) {
    try {
      micStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
    } catch (error) {
      send({ type: 'recorder-warning', message: 'The microphone could not be used, so this recording has no voice.' });
    }
  }

  // Mix tab/system sound and the mic into one track. Tab sound is also sent
  // to the speakers: capturing a tab would otherwise mute it for you.
  const ctx = new AudioContext();
  const dest = ctx.createMediaStreamDestination();
  let hasAudio = false;
  if (display.getAudioTracks().length) {
    const src = ctx.createMediaStreamSource(new MediaStream(display.getAudioTracks()));
    src.connect(dest);
    if (kind === 'tab') src.connect(ctx.destination);
    hasAudio = true;
  }
  if (micStream) {
    const src = ctx.createMediaStreamSource(micStream);
    const gain = ctx.createGain();
    gain.gain.value = 1.4; // voices come in quiet on many laptop mics
    const limiter = ctx.createDynamicsCompressor();
    limiter.threshold.value = -6;
    limiter.ratio.value = 12;
    src.connect(gain).connect(limiter).connect(dest);
    hasAudio = true;
  }

  const tracks = [...display.getVideoTracks(), ...(hasAudio ? dest.stream.getAudioTracks() : [])];
  const stream = new MediaStream(tracks);
  const mimeType = pickMimeType();
  const settings = display.getVideoTracks()[0]?.getSettings?.() || {};
  const pixels = (settings.width || 1920) * (settings.height || 1080);
  const recorder = new MediaRecorder(stream, {
    mimeType: mimeType || undefined,
    videoBitsPerSecond: Math.min(12_000_000, Math.max(2_500_000, Math.round(pixels * 3))),
    audioBitsPerSecond: 160_000,
    // A keyframe every second, so trimming can cut close to where you choose.
    videoKeyFrameIntervalDuration: 1000,
  });

  let seq = 0;
  const writes = [];
  recorder.ondataavailable = (e) => {
    if (e.data && e.data.size > 0) writes.push(putChunk(recId, seq++, e.data));
  };

  session = {
    recId, recorder, display, micStream, ctx, mimeType: recorder.mimeType || mimeType || 'video/webm',
    hasAudio, title, effects, kind,
    width: settings.width || 0, height: settings.height || 0,
    startedAt: performance.now(), pausedAt: null, pausedTotal: 0,
    writes, limitTimer: null, stopping: null, discarded: false,
  };

  // Chrome's own "Stop sharing" button, or the recorded tab closing.
  display.getVideoTracks()[0]?.addEventListener('ended', () => stop('ended'));
  recorder.onerror = (e) => {
    send({ type: 'recorder-error', message: `Recording failed: ${e.error?.message || 'unknown error'}` });
    stop('error');
  };

  recorder.start(1000);
  armLimit(limitSec);
  send({ type: 'recorder-started', recId, mimeType: session.mimeType, hasAudio });
}

function elapsedMs() {
  if (!session) return 0;
  const now = session.pausedAt ?? performance.now();
  return now - session.startedAt - session.pausedTotal;
}

function armLimit(limitSec) {
  if (!session || !limitSec) return;
  clearTimeout(session.limitTimer);
  session.limitSec = limitSec;
  const left = limitSec * 1000 - elapsedMs();
  session.limitTimer = setTimeout(() => {
    send({ type: 'recorder-limit', recId: session?.recId });
    stop('limit');
  }, Math.max(0, left));
}

function pause() {
  if (!session || session.recorder.state !== 'recording') return;
  session.recorder.pause();
  session.pausedAt = performance.now();
  clearTimeout(session.limitTimer);
}

function resume() {
  if (!session || session.recorder.state !== 'paused') return;
  session.pausedTotal += performance.now() - session.pausedAt;
  session.pausedAt = null;
  session.recorder.resume();
  armLimit(session.limitSec);
}

async function stop(reason = 'user', { discard = false } = {}) {
  const s = session;
  if (!s) return null;
  if (s.stopping) return s.stopping;
  s.discarded = discard;
  s.stopping = (async () => {
    clearTimeout(s.limitTimer);
    const durationMs = elapsedMs();
    if (s.recorder.state !== 'inactive') {
      await new Promise((resolve) => {
        s.recorder.addEventListener('stop', resolve, { once: true });
        s.recorder.stop();
      });
    }
    for (const t of [...s.display.getTracks(), ...(s.micStream?.getTracks() || [])]) t.stop();
    s.ctx.close().catch(() => {});
    await Promise.allSettled(s.writes);
    session = null;

    if (s.discarded) {
      await deleteChunks(s.recId);
      send({ type: 'recorder-stopped', recId: s.recId, discarded: true, reason });
      return null;
    }
    send({ type: 'recorder-saving', recId: s.recId });
    const pieces = await readChunks(s.recId);
    let blob = new Blob(pieces, { type: s.mimeType });
    let mime = s.mimeType;
    let codec = /avc1|h264/i.test(mime) ? 'h264' : /vp9/i.test(mime) ? 'vp9' : /vp8/i.test(mime) ? 'vp8' : null;
    let keyframes = [];
    try {
      // Fix the length info MediaRecorder leaves out (seeking, trimming).
      const fixed = await finalizeRecording(blob, mime);
      blob = fixed.blob;
      mime = fixed.mime;
      codec = fixed.codec || codec;
      keyframes = fixed.keyframes;
    } catch (error) {
      console.warn('Could not tidy the recording; keeping it as recorded', error);
    }
    const thumb = await thumbnail(blob).catch(() => null);
    await putRecording({
      id: s.recId,
      title: s.title,
      createdAt: Date.now() - Math.round(durationMs),
      durationMs: Math.round(durationMs),
      mime,
      size: blob.size,
      width: s.width,
      height: s.height,
      hasAudio: s.hasAudio,
      source: s.kind,
      thumb,
      codec,
      keyframes,
      exported: [],
      trimStart: null,
      trimEnd: null,
      blob,
    });
    await deleteChunks(s.recId);
    send({ type: 'recorder-stopped', recId: s.recId, reason, durationMs: Math.round(durationMs) });
    return s.recId;
  })();
  return s.stopping;
}

/** Rebuilds recordings from pieces left by a crash or a closed browser. */
async function recover(ids) {
  for (const recId of ids) {
    if (session?.recId === recId) continue;
    const pieces = await readChunks(recId);
    if (!pieces.length) continue;
    let mime = pieces[0].type || 'video/webm';
    let blob = new Blob(pieces, { type: mime });
    let codec = null;
    let keyframes = [];
    try {
      const fixed = await finalizeRecording(blob, mime);
      blob = fixed.blob;
      mime = fixed.mime;
      codec = fixed.codec;
      keyframes = fixed.keyframes;
    } catch { /* keep as is */ }
    const probe = await probe_(blob);
    await putRecording({
      id: recId,
      title: 'Recovered recording',
      createdAt: Date.now(),
      durationMs: probe.durationMs,
      mime,
      size: blob.size,
      width: probe.width,
      height: probe.height,
      hasAudio: true,
      source: 'recovered',
      thumb: await thumbnail(blob).catch(() => null),
      codec,
      keyframes,
      exported: [],
      trimStart: null,
      trimEnd: null,
      blob,
    });
    await deleteChunks(recId);
  }
}

async function probe_(blob) {
  const url = URL.createObjectURL(blob);
  try {
    const v = document.createElement('video');
    v.muted = true;
    v.src = url;
    await new Promise((resolve) => { v.onloadedmetadata = resolve; v.onerror = resolve; setTimeout(resolve, 5000); });
    return { durationMs: Number.isFinite(v.duration) ? Math.round(v.duration * 1000) : 0, width: v.videoWidth || 0, height: v.videoHeight || 0 };
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** A small JPEG of the recording (about a third of the way in). */
async function thumbnail(blob) {
  const url = URL.createObjectURL(blob);
  try {
    const video = document.createElement('video');
    video.muted = true;
    video.src = url;
    await new Promise((resolve, reject) => {
      video.onloadeddata = resolve;
      video.onerror = () => reject(new Error('unreadable'));
      setTimeout(() => reject(new Error('timeout')), 8000);
    });
    const d = Number.isFinite(video.duration) ? video.duration : 1;
    video.currentTime = Math.min(Math.max(0.2, d * 0.33), Math.max(0, d - 0.1));
    await new Promise((resolve) => { video.onseeked = resolve; setTimeout(resolve, 3000); });
    const w = 480;
    const h = Math.round((w * (video.videoHeight || 9)) / (video.videoWidth || 16));
    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    canvas.getContext('2d').drawImage(video, 0, 0, w, h);
    return canvas.toDataURL('image/jpeg', 0.75);
  } finally {
    URL.revokeObjectURL(url);
  }
}

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.target !== 'offscreen') return false;
  (async () => {
    switch (msg.type) {
      case 'start': await start(msg); return { ok: true };
      case 'pause': pause(); return { ok: true, elapsedMs: elapsedMs() };
      case 'resume': resume(); return { ok: true, elapsedMs: elapsedMs() };
      case 'stop': return { ok: true, recId: await stop('user') };
      case 'discard': await stop('user', { discard: true }); return { ok: true };
      case 'recover': await recover(msg.ids || []); return { ok: true };
      case 'status': return { ok: true, recording: Boolean(session), paused: session?.recorder.state === 'paused', elapsedMs: elapsedMs() };
      default: return { ok: false, error: 'Unknown command' };
    }
  })().then(reply, (error) => reply({
    ok: false, error: error?.message || String(error), cancelled: Boolean(error?.cancelled), retryWithoutAudio: Boolean(error?.retryWithoutAudio),
  }));
  return true;
});

send({ type: 'offscreen-ready' });
