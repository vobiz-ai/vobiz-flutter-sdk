// What the server keeps: the state file (its key, webhook secret and seen
// nonces), and the calls and rooms it holds in memory.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { answerCall, appAuth, postJson, startBridge, webhook } from './helpers.mjs';

test('the state file is 0600', { skip: process.platform === 'win32' && 'POSIX file modes only' }, async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  assert.equal(fs.statSync(ctx.stateFile).mode & 0o777, 0o600);
});

test('a state file from the push version keeps its key, secret and nonces, and loses its devices', async () => {
  const one = await startBridge();
  await one.stop();
  const old = JSON.parse(fs.readFileSync(one.stateFile, 'utf8'));
  const nonceExpiry = Date.now() + 60 * 1000;
  fs.writeFileSync(one.stateFile, JSON.stringify({
    ...old,
    bridgeKey: 'saved-bridge-key-0123456789',
    nonces: { n1: nonceExpiry },
    devices: { dev1: { username: 'alice', token: `fcm-${'x'.repeat(40)}`, secretHash: 'hash' } },
  }));
  const two = await startBridge({ stateFile: one.stateFile, env: { BRIDGE_KEY: '' } });
  try {
    assert.deepEqual(Object.keys(two.bridge.state).sort(), ['bridgeKey', 'nonces', 'webhookSecret']);
    assert.equal(two.bridge.state.bridgeKey, 'saved-bridge-key-0123456789');
    assert.equal(two.bridge.state.webhookSecret, old.webhookSecret);
    assert.deepEqual(two.bridge.state.nonces, { n1: nonceExpiry });
    const saved = fs.readFileSync(one.stateFile, 'utf8');
    assert.doesNotMatch(saved, /devices|fcm-|secretHash/, 'push tokens and device hashes are gone from the file');
  } finally {
    await two.stop();
  }
});

test('the application is found past the first page: Vobiz returns 20 a page whatever the limit', async (t) => {
  const apps = Array.from({ length: 45 }, (_, i) => ({ app_id: `app${i}`, app_name: `other${i}` }));
  apps[44] = { app_id: 'app44', app_name: 'Vobiz_Flutter_Push_Bridge', answer_url: 'https://bridge.example.test/answer', hangup_url: 'https://bridge.example.test/hangup' };
  const ctx = await startBridge({
    env: { VOBIZ_NUMBER: '+918000000001' },
    apiHandler: (method, pathname) => {
      if (method === 'GET' && pathname.startsWith('/Application/')) {
        const offset = Number(new URL(pathname, 'https://x').searchParams.get('offset') || 0);
        return { objects: apps.slice(offset, offset + 20), meta: { total_count: apps.length, limit: 20, offset } };
      }
      if (method === 'GET' && pathname.startsWith('/numbers')) {
        return { items: [{ e164: '+918000000001', application_id: 'app44' }], total: 1, per_page: 100 };
      }
      return { message: 'ok' };
    },
  });
  t.after(ctx.stop);
  await ctx.bridge.linkVobizNumber();
  const offsets = ctx.api.filter((c) => c.pathname.startsWith('/Application/'))
    .map((c) => Number(new URL(c.pathname, 'https://x').searchParams.get('offset')));
  assert.deepEqual(offsets, [0, 20, 40]);
  assert.equal(ctx.api.filter((c) => c.method === 'POST').length, 0, 'found, so nothing was created or moved');
  assert.ok(ctx.logs.some((l) => /already rings this bridge/.test(l)));
});

test('the sweep keeps an answered call that is still up, and forgets the rest', async (t) => {
  const CALL = '11111111-2222-4333-8444-555555555555';
  const ctx = await startBridge({
    env: { ROUTES: '+918000000001=alice', VOBIZ_NUMBER: '+918000000001' },
    apiHandler: (method, pathname) => (method === 'POST' && pathname === '/Call/' ? { request_uuid: 'r1' } : { message: 'ok' }),
  });
  t.after(ctx.stop);
  const call = await answerCall(ctx, { CallUUID: CALL, From: '+919800000001', To: '+918000000001' });
  await webhook(ctx, call.events, { Event: 'DialAnswer', DialAction: 'answer', DialBLegTo: 'sip:alice@registrar.vobiz.ai' });
  await answerCall(ctx, { CallUUID: 'unanswered', From: '+919800000002', To: '+918000000001' });
  await answerCall(ctx, { CallUUID: 'ended', From: '+919800000003', To: '+918000000001' });
  await webhook(ctx, '/hangup', { CallUUID: 'ended', CallStatus: 'completed' });

  const minutes = (n) => Date.now() - n * 60 * 1000;
  for (const record of ctx.bridge.calls.values()) record.createdAt = minutes(11);
  ctx.bridge.sweep();
  assert.deepEqual([...ctx.bridge.calls.keys()], [CALL], 'only the live, answered call is kept after 10 minutes');

  // So the app can still turn it into a conference.
  const added = await postJson(ctx, '/conference/add', { call_uuid: CALL, number: '+919811111111' }, appAuth('alice'));
  assert.equal(added.status, 200, added.text);

  // Nothing is kept past 5 hours: the Dial's timeLimit is 4.
  ctx.bridge.calls.get(CALL).createdAt = minutes(5 * 60 + 1);
  ctx.bridge.sweep();
  assert.equal(ctx.bridge.calls.size, 0);
});
