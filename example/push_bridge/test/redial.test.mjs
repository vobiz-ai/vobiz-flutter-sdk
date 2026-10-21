// #8: no waiting on FCM or fixed sleeps; dial the app as soon as it reports
// that its SIP registration succeeded.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PUBLIC_URL, postJson, registerDevice, startBridge, until, webhook, xmlAttr } from './helpers.mjs';

async function ringingCall(ctx, id = 'c1') {
  await registerDevice(ctx, 'alice');
  const answer = await webhook(ctx, '/answer', { CallUUID: id, From: '+919800000001', To: '+918000000001' });
  const action = new URL(xmlAttr(answer.text, 'Dial', 'action')).pathname;
  const push = await until(() => ctx.pushes.find((p) => p.data.type === 'incoming_call' && p.data.call_id === id));
  return { answer, action, push };
}

test('a slow push does not delay /answer', async (t) => {
  let release;
  const gate = new Promise((r) => { release = r; });
  // A push that hangs until the test ends (the old bridge waited up to 4 s).
  const ctx = await startBridge({ pushDelay: () => gate });
  t.after(() => { release(); return ctx.stop(); });
  await registerDevice(ctx, 'alice');
  const started = Date.now();
  const r = await webhook(ctx, '/answer', { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' });
  assert.match(r.text, /<Dial/);
  assert.ok(Date.now() - started < 1000, `took ${Date.now() - started} ms`);
});

test('a busy result from an offline app is answered at once, without a 1.5 s sleep', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const { action } = await ringingCall(ctx);
  const started = Date.now();
  const r = await webhook(ctx, action, { DialStatus: 'busy' });
  assert.ok(Date.now() - started < 500, `took ${Date.now() - started} ms`);
  assert.match(r.text, /<PreAnswer><Play>[^<]*ringback\.wav<\/Play><\/PreAnswer>/);
});

test('"registered" during ringback transfers the caller to /dial-now, which dials at once', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const { action, push } = await ringingCall(ctx);
  await webhook(ctx, action, { DialStatus: 'failed' }); // now in ringback

  const r = await postJson(ctx, '/push/registered', { call_id: push.data.call_id, call_key: push.data.call_key });
  assert.equal(r.status, 200);
  assert.equal(r.json.redial, 'transferred');
  const transfer = ctx.api.find((c) => c.pathname === '/Call/c1/');
  assert.equal(transfer.method, 'POST');
  assert.equal(transfer.body.legs, 'aleg');
  const target = new URL(transfer.body.aleg_url);
  assert.equal(target.origin, PUBLIC_URL);
  assert.match(target.pathname, /^\/dial-now\/c1\.[\w-]{22}$/);

  const now = await webhook(ctx, target.pathname, { CallUUID: 'c1' });
  assert.match(now.text, /<Dial/);
  assert.doesNotMatch(now.text, /PreAnswer/);
});

test('"registered" while an attempt is in flight makes the next attempt skip the ringback', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const { action, push } = await ringingCall(ctx);
  const r = await postJson(ctx, '/push/registered', { call_id: push.data.call_id, call_key: push.data.call_key });
  assert.equal(r.json.redial, 'next_attempt');
  assert.equal(ctx.api.filter((c) => c.pathname.startsWith('/Call/')).length, 0);
  const next = await webhook(ctx, action, { DialStatus: 'failed' });
  assert.match(next.text, /<Dial/);
  assert.doesNotMatch(next.text, /PreAnswer/);
});

test('if the transfer fails, the next attempt still skips the ringback', async (t) => {
  const ctx = await startBridge({
    apiHandler: (method, pathname) => {
      if (pathname.startsWith('/Call/')) throw new Error('404 not in progress');
      return { objects: [{ username: 'alice' }], meta: { total_count: 1 } };
    },
  });
  t.after(ctx.stop);
  const { action, push } = await ringingCall(ctx);
  await webhook(ctx, action, { DialStatus: 'failed' });
  const r = await postJson(ctx, '/push/registered', { call_id: push.data.call_id, call_key: push.data.call_key });
  assert.equal(r.json.redial, 'next_attempt');
  const next = await webhook(ctx, action, { DialStatus: 'failed' });
  assert.doesNotMatch(next.text, /PreAnswer/);
});

test('"registered" needs the call key or the phone\'s device token', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const { push } = await ringingCall(ctx);
  assert.equal((await postJson(ctx, '/push/registered', { call_id: push.data.call_id, call_key: 'wrong' })).status, 404);
  assert.equal((await postJson(ctx, '/push/registered', {})).status, 401);
});

test('"registered" with the device token redials every call ringing that endpoint', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const alice = await registerDevice(ctx, 'alice');
  const answer = await webhook(ctx, '/answer', { CallUUID: 'c9', From: '+919800000001', To: '+918000000001' });
  const action = new URL(xmlAttr(answer.text, 'Dial', 'action')).pathname;
  const r = await postJson(ctx, '/push/registered', {}, alice.auth);
  assert.deepEqual(r.json.calls, { c9: 'next_attempt' });
  const next = await webhook(ctx, action, { DialStatus: 'failed' });
  assert.doesNotMatch(next.text, /PreAnswer/);
});
