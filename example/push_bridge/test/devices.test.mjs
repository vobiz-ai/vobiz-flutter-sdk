// #13: per-phone credentials, calls pushed only to the dialled endpoint's
// phones, Decline needs the call's key, state file readable by its owner only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { BRIDGE_KEY, fcmToken, postJson, registerDevice, startBridge, webhook, answerCall } from './helpers.mjs';

const ROUTES = '+918000000001=alice;+918000000002=bob';

test('pairing returns a per-phone device token; the bridge stores only its hash', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const alice = await registerDevice(ctx, 'alice');
  assert.match(alice.device_token, /^[\w-]+\.[\w-]+$/);
  const saved = fs.readFileSync(ctx.stateFile, 'utf8');
  assert.ok(!saved.includes(alice.device_token.split('.')[1]), 'device secret is not stored in clear');
});

test('the state file is 0600', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  assert.equal(fs.statSync(ctx.stateFile).mode & 0o777, 0o600);
});

test('a username that is not an endpoint on the account cannot be registered', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const r = await postJson(ctx, '/push/register', { username: 'victim_endpoint_xyz', token: fcmToken('m') }, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(r.status, 403);
  assert.deepEqual(ctx.bridge.state.devices, {});
});

test('registration without the bridge key or a device token is refused', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const r = await postJson(ctx, '/push/register', { username: 'alice', token: fcmToken('m') });
  assert.equal(r.status, 401);
  const forged = await postJson(ctx, '/push/register', { username: 'alice', token: fcmToken('m') }, { Authorization: 'Bearer abc.def' });
  assert.equal(forged.status, 401);
});

test('unregister and test calls need the phone\'s own device token, and touch only that phone', async (t) => {
  const ctx = await startBridge({ env: { ROUTES } });
  t.after(ctx.stop);
  const alice = await registerDevice(ctx, 'alice');
  const bob = await registerDevice(ctx, 'bob');

  assert.equal((await postJson(ctx, '/push/unregister', {}, { 'X-Bridge-Key': BRIDGE_KEY })).status, 401);
  assert.equal((await postJson(ctx, '/push/test', { delay_seconds: 0 }, { 'X-Bridge-Key': BRIDGE_KEY })).status, 401);

  const test1 = await postJson(ctx, '/push/test', { delay_seconds: 0 }, alice.auth);
  assert.equal(test1.status, 200);
  await new Promise((r) => setTimeout(r, 50));
  assert.deepEqual(ctx.pushes.map((p) => p.token), [alice.fcm]);

  assert.equal((await postJson(ctx, '/push/unregister', {}, alice.auth)).status, 200);
  assert.deepEqual(Object.values(ctx.bridge.state.devices).map((d) => d.username), ['bob']);
  assert.equal((await postJson(ctx, '/push/test', { delay_seconds: 0 }, alice.auth)).status, 401, 'token is dead after unregister');
  assert.ok(bob.device_id);
});

test('an inbound call rings and pushes only the dialled number\'s endpoint', async (t) => {
  const ctx = await startBridge({ env: { ROUTES } });
  t.after(ctx.stop);
  const alice = await registerDevice(ctx, 'alice');
  await registerDevice(ctx, 'bob');
  const r = await answerCall(ctx, { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' });
  assert.match(r.text, /sip:alice@/);
  assert.doesNotMatch(r.text, /sip:bob@/);
  await new Promise((res) => setTimeout(res, 50));
  assert.deepEqual(ctx.pushes.map((p) => p.token), [alice.fcm]);
});

test('without ROUTES and several endpoints registered, nobody is pushed', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  await registerDevice(ctx, 'bob');
  const r = await webhook(ctx, '/answer', { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' });
  assert.doesNotMatch(r.text, /<Dial/);
  assert.equal(ctx.pushes.length, 0);
});

test('Decline without the call key (old username + caller fallback) is refused', async (t) => {
  const ctx = await startBridge({ env: { ROUTES } });
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  await webhook(ctx, '/answer', { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' });
  const r = await postJson(ctx, '/push/decline', { username: 'alice', caller: '9800000001' }, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(r.status, 404);
  assert.equal(ctx.bridge.calls.get('c1').declined, false);
});

test('old-layout state (one shared key, devices by username) makes phones pair again', async () => {
  const one = await startBridge();
  await one.stop();
  fs.writeFileSync(one.stateFile, JSON.stringify({ bridgeKey: BRIDGE_KEY, devices: { alice: [{ token: fcmToken('a') }] } }));
  const two = await startBridge({ stateFile: one.stateFile });
  try {
    assert.deepEqual(two.bridge.state.devices, {});
  } finally {
    await two.stop();
  }
});
