// FFmpeg compiled to WebAssembly (the same tool the desktop app uses), loaded
// from the extension's own files. Used to tidy a finished recording, to trim
// it, and to turn WebM into MP4 when Chrome couldn't record MP4 directly.
import { FFmpeg } from '../vendor/ffmpeg/index.js';

let instance = null;
let loading = null;

async function ffmpeg() {
  if (instance) return instance;
  if (loading) return loading;
  loading = (async () => {
    const f = new FFmpeg();
    await f.load({
      coreURL: chrome.runtime.getURL('vendor/ffmpeg-core/ffmpeg-core.js'),
      wasmURL: chrome.runtime.getURL('vendor/ffmpeg-core/ffmpeg-core.wasm'),
    });
    instance = f;
    return f;
  })();
  try {
    return await loading;
  } finally {
    loading = null;
  }
}

export const extensionFor = (mime) => (String(mime).includes('mp4') ? 'mp4' : 'webm');

async function run(input, inName, outName, args, onProgress) {
  const f = await ffmpeg();
  const progress = ({ progress }) => onProgress?.(Math.max(0, Math.min(1, progress || 0)));
  f.on('progress', progress);
  try {
    await f.writeFile(inName, new Uint8Array(await input.arrayBuffer()));
    const code = await f.exec(['-hide_banner', '-y', ...args]);
    if (code !== 0) throw new Error(`FFmpeg exited with ${code}`);
    const data = await f.readFile(outName);
    return data;
  } finally {
    f.off('progress', progress);
    await f.deleteFile(inName).catch(() => {});
    await f.deleteFile(outName).catch(() => {});
  }
}

/** Reads ffprobe's CSV: the video codec, and the time of every keyframe. */
export function parseProbe(text) {
  let codec = null;
  const keyframes = [];
  for (const line of String(text).split(/\r?\n/)) {
    const parts = line.trim().split(',');
    if (parts.length === 1 && /^[a-z0-9_]+$/.test(parts[0]) && !codec) codec = parts[0];
    else if (parts.length >= 2 && /K/.test(parts[1])) {
      const t = Number(parts[0]);
      if (Number.isFinite(t)) keyframes.push(Math.round(t * 1000) / 1000);
    }
  }
  return { codec, keyframes: [...new Set(keyframes)].sort((a, b) => a - b) };
}

/** Video codec and keyframe times of a file already in FFmpeg's memory. */
async function probe(f, name) {
  const out = 'probe.txt';
  try {
    await f.ffprobe(['-v', 'error', '-select_streams', 'v:0',
      '-show_entries', 'stream=codec_name', '-show_entries', 'packet=pts_time,flags',
      '-of', 'csv=p=0', name, '-o', out]);
    const text = new TextDecoder().decode(await f.readFile(out));
    return parseProbe(text);
  } catch {
    return { codec: null, keyframes: [] };
  } finally {
    await f.deleteFile(out).catch(() => {});
  }
}

/**
 * Rewrites the file without re-encoding so it has a proper length and index
 * (MediaRecorder leaves those out, which breaks seeking and trimming), and
 * notes its codec and keyframes (where a fast trim can start).
 */
export async function finalizeRecording(blob, mime) {
  const ext = extensionFor(mime);
  const inName = `in.${ext}`;
  const out = `fixed.${ext}`;
  const f = await ffmpeg();
  try {
    await f.writeFile(inName, new Uint8Array(await blob.arrayBuffer()));
    const code = await f.exec(['-hide_banner', '-y', '-i', inName, '-map', '0', '-c', 'copy',
      ...(ext === 'mp4' ? ['-movflags', '+faststart'] : []), out]);
    if (code !== 0) throw new Error(`FFmpeg exited with ${code}`);
    const info = await probe(f, out);
    const data = await f.readFile(out);
    const type = ext === 'mp4' ? 'video/mp4' : 'video/webm';
    return { blob: new Blob([data.buffer], { type }), mime: type, codec: info.codec, keyframes: info.keyframes };
  } finally {
    await f.deleteFile(inName).catch(() => {});
    await f.deleteFile(out).catch(() => {});
  }
}

/** Codecs each download format can hold without re-encoding (plays everywhere). */
const FITS = { mp4: ['h264'], webm: ['vp8', 'vp9', 'av1'] };

/** Whether downloading as [format] needs a (slow) re-encode. */
export const needsReencode = (codec, format, mime) =>
  extensionFor(mime) !== format || !codec || !FITS[format].includes(codec);

/** The first keyframe at or after [t] (where a fast trim can start). */
export function keyframeAtOrAfter(keyframes, t) {
  if (!keyframes?.length) return t;
  return keyframes.find((k) => k >= t - 0.02) ?? keyframes[keyframes.length - 1];
}

/**
 * The file to download: the kept part (start/end in seconds, or the whole
 * recording), as MP4 or WebM. Keeps quality by copying where it can.
 */
export async function exportRecording(blob, mime, { start = null, end = null, format = 'mp4', duration = 0, codec = null } = {}, onProgress) {
  const from = extensionFor(mime);
  const trimmed = (start != null && start > 0.05) || (end != null && duration && end < duration - 0.05);
  const reencode = needsReencode(codec, format, mime);
  if (!trimmed && !reencode) return blob;
  const inName = `in.${from}`;
  const outName = `out.${format}`;
  const cut = [
    ...(start != null && start > 0.05 ? ['-ss', start.toFixed(3)] : []),
    ...(end != null ? ['-to', end.toFixed(3)] : []),
  ];
  const args = !reencode
    ? [...cut, '-i', inName, '-map', '0', '-c', 'copy', '-avoid_negative_ts', 'make_zero',
      ...(format === 'mp4' ? ['-movflags', '+faststart'] : []), outName]
    : format === 'mp4'
      ? [...cut, '-i', inName, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '22', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart', outName]
      : [...cut, '-i', inName, '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '32', '-deadline', 'realtime', '-c:a', 'libopus', outName];
  const data = await run(blob, inName, outName, args, onProgress);
  return new Blob([data.buffer], { type: format === 'mp4' ? 'video/mp4' : 'video/webm' });
}
