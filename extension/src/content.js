// On-page layer while recording: a small control bar (time, pause, finish,
// discard), the yellow cursor halo and click ripples, and the face-camera
// bubble. Everything lives in a closed shadow root so pages can't restyle it.
(() => {
  if (window.__screenRecorderOverlay) {
    window.__screenRecorderOverlay.refresh();
    return;
  }

  const host = document.createElement('screen-recorder-overlay');
  host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
  const root = host.attachShadow({ mode: 'closed' });
  const font = chrome.runtime.getURL('fonts/inter-tight.woff2');
  root.innerHTML = `
<style>
@font-face{font-family:"SR Inter";src:url(${font}) format("woff2");font-weight:100 900}
*{box-sizing:border-box;margin:0;font-family:"SR Inter",system-ui,-apple-system,"Segoe UI",sans-serif}
.halo{position:fixed;left:0;top:0;width:44px;height:44px;margin:-22px 0 0 -22px;border-radius:50%;
  background:rgba(255,210,31,.28);border:2px solid rgba(255,210,31,.85);pointer-events:none;
  transition:width .12s,height .12s,margin .12s,opacity .2s;opacity:0}
.halo.on{opacity:1}
.halo.down{width:34px;height:34px;margin:-17px 0 0 -17px;background:rgba(255,210,31,.45)}
.ripple{position:fixed;width:16px;height:16px;margin:-8px 0 0 -8px;border-radius:50%;border:3px solid #FFD21F;
  pointer-events:none;animation:rip .55s ease-out forwards}
@keyframes rip{to{transform:scale(4.2);opacity:0}}
.bar{position:fixed;left:18px;bottom:18px;display:flex;align-items:center;gap:4px;padding:6px;border-radius:14px;
  background:#111;color:#fff;box-shadow:0 10px 30px -8px rgba(0,0,0,.5);pointer-events:auto;user-select:none;cursor:grab;font-size:13px}
.bar:active{cursor:grabbing}
.time{display:flex;align-items:center;gap:8px;padding:0 10px 0 8px;font-weight:600;font-variant-numeric:tabular-nums;min-width:74px}
.dot{width:9px;height:9px;border-radius:50%;background:#E5483B;animation:pulse 1.2s ease-in-out infinite}
.paused .dot{animation:none;background:#A1A1A6}
@keyframes pulse{50%{opacity:.35}}
button{all:unset;display:inline-flex;align-items:center;gap:6px;height:32px;padding:0 10px;border-radius:9px;cursor:pointer;
  font:600 13px "SR Inter",system-ui,sans-serif;color:#fff;background:#2A2A2D}
button:hover{background:#3A3A3E}
button.stop{background:#fff;color:#111}
button.stop:hover{background:#E8E8ED}
button:focus-visible{outline:2px solid #0080FF;outline-offset:2px}
.limit{color:#FFD21F}
.cam{position:fixed;right:24px;bottom:24px;width:180px;height:180px;border-radius:50%;overflow:hidden;pointer-events:auto;
  cursor:grab;box-shadow:0 12px 30px -10px rgba(0,0,0,.55);border:3px solid #fff;background:#222}
.cam iframe{width:100%;height:100%;border:0;pointer-events:none}
.toast{position:fixed;left:50%;top:18px;transform:translateX(-50%);max-width:min(560px,90vw);padding:10px 14px;border-radius:10px;
  background:#111;color:#fff;font-size:13px;line-height:1.4;pointer-events:auto;box-shadow:0 10px 30px -10px rgba(0,0,0,.5)}
.hidden{display:none!important}
</style>
<div class="halo"></div>
<div class="cam hidden"></div>
<div class="bar hidden" role="toolbar" aria-label="Screen Recorder">
  <span class="time"><span class="dot"></span><span class="clock">0:00</span></span>
  <button class="pause" title="Pause (the recording waits for you)">Pause</button>
  <button class="stop" title="Stop and open the editor">■ Finish</button>
  <button class="discard" title="Stop and throw this recording away">✕</button>
</div>
<div class="toast hidden" role="status"></div>`;
  (document.body || document.documentElement).appendChild(host);

  const $ = (s) => root.querySelector(s);
  const bar = $('.bar');
  const halo = $('.halo');
  const cam = $('.cam');
  let rec = { status: 'idle' };
  let ticker = null;
  let toastTimer = null;

  const send = (type, extra = {}) => chrome.runtime.sendMessage({ type, ...extra }).catch(() => null);

  function elapsed() {
    if (!rec.startedAt) return 0;
    const end = rec.pausedAt || Date.now();
    return Math.max(0, (end - rec.startedAt - (rec.pausedTotal || 0)) / 1000);
  }

  function tick() {
    const s = elapsed();
    const clock = `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
    const left = rec.limitSec ? rec.limitSec - s : null;
    const el = $('.clock');
    if (left != null && left <= 30) {
      el.textContent = `${clock} · trial ends in ${Math.max(0, Math.ceil(left))}s`;
      el.classList.add('limit');
    } else {
      el.textContent = clock;
      el.classList.remove('limit');
    }
  }

  function apply(next) {
    rec = next || { status: 'idle' };
    const live = rec.status === 'recording' || rec.status === 'paused';
    if (!live) {
      clearInterval(ticker);
      host.remove();
      window.removeEventListener('mousemove', onMove, true);
      window.removeEventListener('mousedown', onDown, true);
      window.removeEventListener('mouseup', onUp, true);
      delete window.__screenRecorderOverlay;
      return;
    }
    bar.classList.remove('hidden');
    bar.classList.toggle('paused', rec.status === 'paused');
    $('.pause').textContent = rec.status === 'paused' ? '▶ Resume' : '❚❚ Pause';
    halo.classList.toggle('hidden', !rec.effects);
    if (rec.camera && cam.classList.contains('hidden')) {
      const frame = document.createElement('iframe');
      frame.src = chrome.runtime.getURL('camera.html');
      frame.allow = 'camera';
      frame.title = 'Your camera';
      cam.replaceChildren(frame);
      cam.classList.remove('hidden');
    } else if (!rec.camera) {
      cam.classList.add('hidden');
      cam.replaceChildren();
    }
    clearInterval(ticker);
    tick();
    ticker = setInterval(tick, 500);
  }

  function toast(text) {
    const t = $('.toast');
    t.textContent = text;
    t.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.add('hidden'), 6000);
  }

  // Cursor halo and click ripples (drawn on the page, so they're recorded).
  function onMove(e) {
    if (!rec.effects) return;
    halo.style.transform = `translate(${e.clientX}px, ${e.clientY}px)`;
    halo.classList.add('on');
  }
  function onDown(e) {
    if (!rec.effects || e.button !== 0) return;
    halo.classList.add('down');
    const r = document.createElement('div');
    r.className = 'ripple';
    r.style.left = `${e.clientX}px`;
    r.style.top = `${e.clientY}px`;
    root.appendChild(r);
    setTimeout(() => r.remove(), 700);
  }
  function onUp() { halo.classList.remove('down'); }
  window.addEventListener('mousemove', onMove, true);
  window.addEventListener('mousedown', onDown, true);
  window.addEventListener('mouseup', onUp, true);
  document.addEventListener('mouseleave', () => halo.classList.remove('on'));

  // Drag the bar and the camera bubble anywhere.
  function draggable(el, { keepBottomLeft = false } = {}) {
    let start = null;
    el.addEventListener('pointerdown', (e) => {
      if (e.target.closest('button')) return;
      const r = el.getBoundingClientRect();
      start = { x: e.clientX, y: e.clientY, left: r.left, top: r.top };
      el.setPointerCapture(e.pointerId);
    });
    el.addEventListener('pointermove', (e) => {
      if (!start) return;
      const r = el.getBoundingClientRect();
      const left = Math.min(Math.max(4, start.left + e.clientX - start.x), innerWidth - r.width - 4);
      const top = Math.min(Math.max(4, start.top + e.clientY - start.y), innerHeight - r.height - 4);
      el.style.left = `${left}px`;
      el.style.top = `${top}px`;
      el.style.right = 'auto';
      el.style.bottom = 'auto';
    });
    el.addEventListener('pointerup', () => { start = null; });
    void keepBottomLeft;
  }
  draggable(bar);
  draggable(cam);

  $('.pause').addEventListener('click', () => send(rec.status === 'paused' ? 'resume' : 'pause'));
  $('.stop').addEventListener('click', () => { $('.stop').textContent = 'Saving…'; send('stop'); });
  $('.discard').addEventListener('click', () => {
    // eslint-disable-next-line no-alert
    if (window.confirm('Throw this recording away? It will not be saved.')) send('discard');
  });

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type === 'state') apply(msg.rec);
    if (msg?.type === 'notice') toast(msg.text);
  });

  const refresh = () => send('state').then((r) => r?.ok && apply(r.value));
  window.__screenRecorderOverlay = { refresh };
  refresh();
})();
