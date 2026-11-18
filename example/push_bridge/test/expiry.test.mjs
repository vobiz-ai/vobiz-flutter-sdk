// #50: the push says how long it is valid for, not a wall-clock deadline the
// phone would compare with its own (possibly wrong) clock.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { registerDevice, startBridge, until, webhook, postJson } from './helpers.mjs';

test('incoming_call carries ttl_ms = the push wait + the ring, and FCM gets the same TTL', async (t) => {
  const ctx = await startBridge({ env: { RING_SECONDS: '30', PUSH_WAIT_SECONDS: '5' } });
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  await webhook(ctx, '/answer', { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' });
  const push = await until(() => ctx.pushes.find((p) => p.data.type === 'incoming_call'));
  const ttl = Number(push.data.ttl_ms);
  assert.ok(ttl > 34000 && ttl <= 35000, `ttl_ms ${push.data.ttl_ms}`);
  assert.ok(push.opts.ttlSeconds >= 34 && push.opts.ttlSeconds <= 35, `FCM ttl ${push.opts.ttlSeconds}`);
});

test('a delayed test call\'s TTL counts from when it is sent', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const alice = await registerDevice(ctx, 'alice');
  await postJson(ctx, '/push/test', { delay_seconds: 0 }, alice.auth);
  const push = await until(() => ctx.pushes.find((p) => p.data.type === 'incoming_call'));
  const ttl = Number(push.data.ttl_ms);
  assert.ok(ttl > 29000 && ttl <= 30000, `ttl_ms ${push.data.ttl_ms}`);
});
