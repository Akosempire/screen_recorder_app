// Unit tests for the extension's pure helpers (run after `npm run build`).
import assert from 'node:assert/strict';
import test from 'node:test';
import { clock, dateLabel } from '../dist/lib/db.js';
import { keyframeAtOrAfter, needsReencode, parseProbe } from '../dist/lib/ffmpeg.js';
import { safeName } from '../dist/lib/names.js';
import { isPro } from '../dist/lib/pro.js';

test('ffprobe output: codec and keyframes', () => {
  const text = 'h264\n0.000000,K__\n0.033000,___\n1.029750,K__\n1.062000,___\n2.078900,K_\n';
  assert.deepEqual(parseProbe(text), { codec: 'h264', keyframes: [0, 1.03, 2.079] });
  assert.deepEqual(parseProbe(''), { codec: null, keyframes: [] });
});

test('a fast trim starts on the first keyframe at or after the chosen time', () => {
  const k = [0, 1.03, 2.079, 3.128];
  assert.equal(keyframeAtOrAfter(k, 1.0), 1.03);
  assert.equal(keyframeAtOrAfter(k, 1.03), 1.03);
  assert.equal(keyframeAtOrAfter(k, 2.5), 3.128);
  assert.equal(keyframeAtOrAfter(k, 9), 3.128);
  assert.equal(keyframeAtOrAfter([], 1.7), 1.7);
});

test('MP4 downloads are always H.264 (plays everywhere); others are re-encoded', () => {
  assert.equal(needsReencode('h264', 'mp4', 'video/mp4'), false);
  assert.equal(needsReencode('vp9', 'mp4', 'video/mp4'), true);
  assert.equal(needsReencode('vp9', 'webm', 'video/webm'), false);
  assert.equal(needsReencode('vp8', 'mp4', 'video/webm'), true);
  assert.equal(needsReencode(null, 'mp4', 'video/mp4'), true);
});

test('download names are plain and safe', () => {
  assert.equal(safeName('Recording · Today, 04:28'), 'Recording - Today, 04-28');
  assert.equal(safeName('Démo: sales/Q3?'), 'Demo- sales-Q3');
  assert.equal(safeName('...'), 'Recording');
  assert.equal(safeName(''), 'Recording');
  assert.ok(safeName('x'.repeat(300)).length <= 100);
});

test('dates and clock', () => {
  const now = new Date(2026, 10, 3, 15, 0).getTime();
  assert.equal(dateLabel(new Date(2026, 10, 3, 9, 5).getTime(), now), 'Today, 09:05');
  assert.equal(dateLabel(new Date(2026, 10, 2, 22, 30).getTime(), now), 'Yesterday, 22:30');
  assert.equal(dateLabel(new Date(2026, 9, 20, 8, 0).getTime(), now), '20 Oct, 08:00');
  assert.equal(clock(65.9), '1:05');
  assert.equal(clock(-3), '0:00');
});

test('Pro: lifetime always, monthly for 14 days after the last check', () => {
  const now = Date.now();
  assert.equal(isPro(null), false);
  assert.equal(isPro({ active: true, plan: 'lifetime', checkedAt: 0 }, now), true);
  assert.equal(isPro({ active: true, plan: 'monthly', checkedAt: now - 3 * 86400_000 }, now), true);
  assert.equal(isPro({ active: true, plan: 'monthly', checkedAt: now - 20 * 86400_000 }, now), false);
  assert.equal(isPro({ active: false, plan: 'lifetime' }, now), false);
});
