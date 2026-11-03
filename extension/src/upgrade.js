import { activateKey, buy, checkPayment, isPro, license, manageUrl, refreshLicense, removeLicense } from './lib/pro.js';

const $ = (id) => document.getElementById(id);
let plan = 'lifetime';
let checkoutUrl = null;
let poll = null;

function show(view) {
  for (const id of ['buy', 'waiting', 'pro']) $(id).hidden = id !== view;
}

async function renderPro(l) {
  show('pro');
  $('pro-plan').textContent = l.plan === 'lifetime'
    ? 'Lifetime: no limits, no renewals.'
    : l.endsAt ? `Monthly, cancelled: works until ${new Date(l.endsAt).toLocaleDateString()}.`
      : `Monthly${l.renews ? `, renews ${new Date(l.renews).toLocaleDateString()}` : ''}.`;
  $('pro-key').textContent = l.key || '';
  $('manage').hidden = !l.canManage;
}

function waitForPayment() {
  show('waiting');
  clearInterval(poll);
  poll = setInterval(async () => {
    try {
      const l = await checkPayment();
      if (l) {
        clearInterval(poll);
        renderPro({ ...l, checkedAt: Date.now() });
      }
    } catch { /* keep waiting */ }
  }, 4000);
}

for (const b of document.querySelectorAll('.plan')) {
  b.addEventListener('click', () => {
    plan = b.dataset.plan;
    for (const x of document.querySelectorAll('.plan')) x.setAttribute('aria-pressed', String(x === b));
  });
}

$('form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const msg = $('buy-msg');
  msg.className = 'msg err';
  const name = f.name.value.trim();
  const email = f.email.value.trim();
  if (!name) { msg.textContent = 'Enter your name.'; return f.name.focus(); }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) { msg.textContent = 'Enter a valid email address, like you@example.com.'; return f.email.focus(); }
  $('pay').disabled = true;
  msg.textContent = '';
  try {
    checkoutUrl = await buy({ plan, name, email });
    await chrome.tabs.create({ url: checkoutUrl });
    waitForPayment();
  } catch (error) {
    msg.textContent = error.message;
  } finally {
    $('pay').disabled = false;
  }
});

$('activate').addEventListener('click', async () => {
  const msg = $('key-msg');
  msg.className = 'msg err';
  msg.textContent = '';
  try {
    const l = await activateKey($('key').value);
    renderPro(l);
  } catch (error) {
    msg.textContent = error.message;
  }
});

$('reopen').addEventListener('click', () => checkoutUrl && chrome.tabs.create({ url: checkoutUrl }));
$('cancel').addEventListener('click', async () => {
  clearInterval(poll);
  await chrome.storage.local.remove('pendingActivation');
  show('buy');
});
$('manage').addEventListener('click', async () => {
  try {
    chrome.tabs.create({ url: await manageUrl() });
  } catch (error) {
    $('pro-msg').className = 'msg err';
    $('pro-msg').textContent = error.message;
  }
});
$('remove').addEventListener('click', async () => {
  // eslint-disable-next-line no-alert
  if (!confirm('Remove Pro from this browser? You can add it back with your licence key.')) return;
  await removeLicense();
  show('buy');
});

(async () => {
  const l = await refreshLicense({ force: true }) || await license();
  if (isPro(l)) return renderPro(l);
  const { pendingActivation } = await chrome.storage.local.get('pendingActivation');
  if (pendingActivation && Date.now() - pendingActivation.at < 3600_000) return waitForPayment();
  show('buy');
})();
