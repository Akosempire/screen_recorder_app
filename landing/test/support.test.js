import test from 'node:test';
import assert from 'node:assert/strict';
import { readRequest, requestEmail, saveRequest } from '../lib/support.js';
import { tooMany } from '../api/support.js';

test('a help request is checked and tidied', () => {
  assert.match(readRequest({ message: 'hi' }).error, /more/);
  assert.match(readRequest({ message: 'It crashed when I stopped', email: 'nope' }).error, /email/);
  const { row } = readRequest(
    { message: '  My 2-hour class was lost  ', email: 'Ada@Example.com', kind: 'weird', appVersion: '1.0.57', os: 'Windows 11' },
    { 'x-vercel-ip-country': 'NG' },
  );
  assert.equal(row.message, 'My 2-hour class was lost');
  assert.equal(row.email, 'ada@example.com');
  assert.equal(row.kind, 'problem');
  assert.equal(row.source, 'app');
  assert.equal(row.country, 'NG');
  assert.equal(readRequest({ message: 'No email is fine too' }).row.email, null);
});

test('saved to support_requests, or to the activity log before the table exists', async () => {
  const rows = [];
  const ok = { insert: async (table, row) => { rows.push([table, row]); return { id: 7 }; } };
  const { row } = readRequest({ message: 'Export never finishes', email: 'a@b.co' });
  assert.deepEqual(await saveRequest(ok, row), { stored: 'support_requests', id: 7 });

  const missing = { insert: async (table, r) => { if (table === 'support_requests') throw new Error('relation does not exist'); rows.push([table, r]); } };
  assert.deepEqual(await saveRequest(missing, row), { stored: 'admin_log' });
  const [table, logged] = rows.at(-1);
  assert.equal(table, 'admin_log');
  assert.equal(logged.action, 'help_problem');
  assert.match(logged.detail, /Export never finishes/);
});

test('admins get a readable email; user text is escaped', () => {
  const { row } = readRequest({ message: '<script>x</script> it froze', email: 'a@b.co', kind: 'question', appVersion: '1.0.57' });
  const mail = requestEmail(row);
  assert.match(mail.subject, /^Question from a@b.co/);
  assert.ok(!mail.html.includes('<script>'));
  assert.match(mail.text, /Version 1.0.57/);
});

test('one address cannot flood the inbox', () => {
  const now = 1_000_000;
  for (let i = 0; i < 6; i++) assert.equal(tooMany('1.2.3.4', now + i), false);
  assert.equal(tooMany('1.2.3.4', now + 10), true);
  assert.equal(tooMany('5.6.7.8', now + 10), false);
  assert.equal(tooMany('1.2.3.4', now + 2 * 60 * 60 * 1000), false);
});
