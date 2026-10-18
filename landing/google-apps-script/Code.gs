/**
 * Screen Recorder sign-ups: Google Sheet + download-link email.
 *
 * Paste this into Extensions > Apps Script of your Google Sheet, set the
 * SECRET script property, and deploy as a Web app (see landing/README.md).
 *
 * The landing site POSTs JSON here:
 *   { secret, action: "signup", name, email, updates, link, linkDays, country, userAgent }
 *   { secret, action: "download", email, country, userAgent }
 */

var SHEET_NAME = 'Sign-ups';
var HEADERS = ['Time', 'Event', 'Name', 'Email', 'Wants updates', 'Country', 'Browser'];
var FROM_NAME = 'Screen Recorder';

function doPost(e) {
  try {
    var body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    var secret = PropertiesService.getScriptProperties().getProperty('SECRET');
    if (!secret || body.secret !== secret) {
      return json_({ ok: false, error: 'Not allowed.' });
    }
    var email = String(body.email || '').trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
      return json_({ ok: false, error: 'Bad email.' });
    }

    if (body.action === 'signup') {
      var name = String(body.name || '').trim().slice(0, 80);
      var link = String(body.link || '');
      if (!/^https:\/\//.test(link)) return json_({ ok: false, error: 'Missing download link.' });
      sendLink_(name, email, link, Number(body.linkDays) || 7);
      addRow_(['signed up', name, email, body.updates ? 'yes' : 'no', body.country || '', body.userAgent || '']);
      return json_({ ok: true });
    }
    if (body.action === 'download') {
      addRow_(['downloaded', '', email, '', body.country || '', body.userAgent || '']);
      return json_({ ok: true });
    }
    return json_({ ok: false, error: 'Unknown action.' });
  } catch (err) {
    console.error(err);
    return json_({ ok: false, error: String(err && err.message || err) });
  }
}

function addRow_(values) {
  var lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    var book = SpreadsheetApp.getActiveSpreadsheet();
    var sheet = book.getSheetByName(SHEET_NAME) || book.insertSheet(SHEET_NAME);
    if (sheet.getLastRow() === 0) {
      sheet.appendRow(HEADERS);
      sheet.setFrozenRows(1);
      sheet.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
    }
    // Stop typed values like "=HYPERLINK(...)" from running as formulas.
    var safe = values.map(function (v) {
      var text = String(v);
      return /^[=+\-@]/.test(text) ? "'" + text : text;
    });
    sheet.appendRow([new Date()].concat(safe));
  } finally {
    lock.releaseLock();
  }
}

function sendLink_(name, email, link, days) {
  if (!/^https:\/\//.test(link)) throw new Error('Missing download link.');
  var first = (name || '').split(' ')[0] || 'there';
  var html =
    '<div style="font-family:Segoe UI,Arial,sans-serif;color:#15171A;max-width:480px;line-height:1.55">' +
    '<p>Hi ' + escape_(first) + ',</p>' +
    '<p>Here is your download link for Screen Recorder for Windows:</p>' +
    '<p style="margin:24px 0"><a href="' + link + '" style="background:#15171A;color:#ffffff;' +
    'text-decoration:none;font-weight:600;padding:12px 18px;border-radius:10px;display:inline-block">' +
    'Download Screen Recorder</a></p>' +
    '<p>Open <b>ScreenRecorder-Setup.exe</b> and a Screen Recorder shortcut appears on your desktop. ' +
    'If Windows says "Windows protected your PC", click <b>More info</b>, then <b>Run anyway</b>.</p>' +
    '<p style="color:#5E6670;font-size:13px">This link works for ' + days + ' days. ' +
    'You received this because you asked for the download on our website.</p>' +
    '</div>';
  MailApp.sendEmail({
    to: email,
    subject: 'Your Screen Recorder download link',
    htmlBody: html,
    body: 'Hi ' + first + ',\n\nDownload Screen Recorder for Windows: ' + link +
      '\n\nThis link works for ' + days + ' days.',
    name: FROM_NAME,
  });
}

function escape_(s) {
  return String(s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

/** Run once from the editor to approve Sheet + email permissions. */
function authorize() {
  SpreadsheetApp.getActiveSpreadsheet().getName();
  MailApp.getRemainingDailyQuota();
}
