// Recordings live in IndexedDB (extension origin, shared by the offscreen
// recorder, the popup and the editor). While recording, pieces are written
// every second to `chunks`, so a crash or a closed browser loses at most a
// second; on stop they are joined into one `recordings` entry.

const DB_NAME = 'screen-recorder';
const VERSION = 1;

let opening;

export function openDb() {
  if (opening) return opening;
  opening = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('recordings')) {
        const s = db.createObjectStore('recordings', { keyPath: 'id' });
        s.createIndex('createdAt', 'createdAt');
      }
      if (!db.objectStoreNames.contains('chunks')) {
        const c = db.createObjectStore('chunks', { keyPath: ['recId', 'seq'] });
        c.createIndex('recId', 'recId');
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => { opening = undefined; reject(req.error); };
  });
  return opening;
}

function tx(db, stores, mode, fn) {
  return new Promise((resolve, reject) => {
    const t = db.transaction(stores, mode);
    let result;
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error || new Error('Transaction aborted'));
    result = fn(t);
  });
}

const reqDone = (req) => new Promise((resolve, reject) => {
  req.onsuccess = () => resolve(req.result);
  req.onerror = () => reject(req.error);
});

export async function putChunk(recId, seq, blob) {
  const db = await openDb();
  await tx(db, ['chunks'], 'readwrite', (t) => { t.objectStore('chunks').put({ recId, seq, blob }); });
}

export async function readChunks(recId) {
  const db = await openDb();
  const t = db.transaction(['chunks'], 'readonly');
  const rows = await reqDone(t.objectStore('chunks').index('recId').getAll(IDBKeyRange.only(recId)));
  return rows.sort((a, b) => a.seq - b.seq).map((r) => r.blob);
}

export async function deleteChunks(recId) {
  const db = await openDb();
  await tx(db, ['chunks'], 'readwrite', (t) => {
    const idx = t.objectStore('chunks').index('recId');
    idx.openKeyCursor(IDBKeyRange.only(recId)).onsuccess = (e) => {
      const cur = e.target.result;
      if (cur) { t.objectStore('chunks').delete(cur.primaryKey); cur.continue(); }
    };
  });
}

/** Recording ids that still have chunks but no finished entry (after a crash). */
export async function orphanChunkIds() {
  const db = await openDb();
  const t = db.transaction(['chunks', 'recordings'], 'readonly');
  const keys = await reqDone(t.objectStore('chunks').getAllKeys());
  const ids = [...new Set(keys.map((k) => k[0]))];
  const out = [];
  for (const id of ids) {
    const rec = await reqDone(db.transaction(['recordings'], 'readonly').objectStore('recordings').get(id));
    if (!rec) out.push(id);
  }
  return out;
}

export async function putRecording(rec) {
  const db = await openDb();
  await tx(db, ['recordings'], 'readwrite', (t) => { t.objectStore('recordings').put(rec); });
  notifyChanged();
}

export async function getRecording(id) {
  const db = await openDb();
  return reqDone(db.transaction(['recordings'], 'readonly').objectStore('recordings').get(id));
}

/** Newest first, without the video blobs (cheap for lists). */
export async function listRecordings() {
  const db = await openDb();
  const all = await reqDone(db.transaction(['recordings'], 'readonly').objectStore('recordings').getAll());
  return all
    .map(({ blob, ...meta }) => ({ ...meta, size: meta.size ?? blob?.size ?? 0 }))
    .sort((a, b) => b.createdAt - a.createdAt);
}

export async function updateRecording(id, fields) {
  const rec = await getRecording(id);
  if (!rec) return null;
  const next = { ...rec, ...fields };
  await putRecording(next);
  return next;
}

export async function deleteRecording(id) {
  const db = await openDb();
  await tx(db, ['recordings'], 'readwrite', (t) => { t.objectStore('recordings').delete(id); });
  await deleteChunks(id);
  notifyChanged();
}

function notifyChanged() {
  try { chrome.runtime.sendMessage({ type: 'recordings-changed' }).catch(() => {}); } catch { /* no listeners */ }
}

export function newId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

/** "Today, 10:42" / "Yesterday, 22:30" / "20 Oct, 08:00". */
export function dateLabel(ms, now = Date.now()) {
  const t = new Date(ms);
  const n = new Date(now);
  const time = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}`;
  const day = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diff = Math.round((day(n) - day(t)) / 86400000);
  if (diff === 0) return `Today, ${time}`;
  if (diff === 1) return `Yesterday, ${time}`;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return `${t.getDate()} ${months[t.getMonth()]}${t.getFullYear() !== n.getFullYear() ? ` ${t.getFullYear()}` : ''}, ${time}`;
}

export function clock(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}
