// #12: webhooks fail closed, are checked against the documented V3/V2
// scheme, cannot be replayed, and a Dial callback's call id is signed.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createBridge } from '../push-bridge.mjs';
import { AUTH_TOKEN, PUBLIC_URL, answerCall, signV3, startBridge, webhook } from './helpers.mjs';

const RINGS_ALICE = { env: { ALWAYS_RING: 'alice' } };

test('refuses to start without PUBLIC_URL', () => {
  assert.throws(
    () => createBridge({ env: { VOBIZ_AUTH_TOKEN: AUTH_TOKEN }, stateFile: '/nonexistent/x.json' }),
    (e) => e.code === 'BRIDGE_CONFIG' && /PUBLIC_URL/.test(e.message),
  );
});

test('refuses to start without the Auth Token', () => {
  assert.throws(
    () => createBridge({ env: { PUBLIC_URL }, stateFile: '/nonexistent/x.json' }),
    (e) => e.code === 'BRIDGE_CONFIG' && /VOBIZ_AUTH_TOKEN/.test(e.message),
  );
});

test('refuses a plain-http PUBLIC_URL and the old VERIFY_SIGNATURES=false switch', () => {
  assert.throws(() => createBridge({ env: { PUBLIC_URL: 'http://x.test', VOBIZ_AUTH_TOKEN: AUTH_TOKEN } }), /https/);
  assert.throws(
    () => createBridge({ env: { PUBLIC_URL, VOBIZ_AUTH_TOKEN: AUTH_TOKEN, VERIFY_SIGNATURES: 'false' } }),
    /ALLOW_UNSIGNED_WEBHOOKS/,
  );
});

test('only ALLOW_UNSIGNED_WEBHOOKS=true turns the check off', async (t) => {
  const ctx = await startBridge({ env: { PUBLIC_URL: '', VOBIZ_AUTH_TOKEN: '', ALLOW_UNSIGNED_WEBHOOKS: 'true' } });
  t.after(ctx.stop);
  assert.equal(ctx.bridge.verifySignatures, false);
  const r = await webhook(ctx, '/hangup', { CallUUID: 'x' }, { sign: false });
  assert.equal(r.status, 200);
});

test('an unsigned /answer is rejected and rings nobody', async (t) => {
  const ctx = await startBridge(RINGS_ALICE);
  t.after(ctx.stop);
  assert.equal(ctx.bridge.verifySignatures, true);
  const r = await webhook(ctx, '/answer', { CallUUID: 'c1', From: '+919800000001', To: '+918000000000' }, { sign: false });
  assert.equal(r.status, 403);
  assert.doesNotMatch(r.text, /<Dial/);
  assert.equal(ctx.bridge.calls.size, 0);
});

test('a signature over a different path or with the wrong token is rejected', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const wrongPath = signV3(`${PUBLIC_URL}/hangup`);
  let r = await webhook(ctx, '/answer', { CallUUID: 'c1' }, { sign: false, headers: wrongPath });
  assert.equal(r.status, 403);
  const wrongToken = signV3(`${PUBLIC_URL}/answer`, { token: 'another-token' });
  r = await webhook(ctx, '/answer', { CallUUID: 'c1' }, { sign: false, headers: wrongToken });
  assert.equal(r.status, 403);
});

test('a signed /answer is accepted; replaying the same nonce with another body is rejected', async (t) => {
  const ctx = await startBridge(RINGS_ALICE);
  t.after(ctx.stop);
  const first = await webhook(ctx, '/answer', { CallUUID: 'c1', From: '+919800000001', To: '+918000000000' });
  assert.equal(first.status, 200);
  assert.match(first.text, /<Dial [^>]*action="[^"]*\/dial-result\/c1\.[\w-]{22}"/);
  const replay = await webhook(ctx, '/answer', { CallUUID: 'c2', From: '+910000000000' }, { sign: false, headers: first.headers });
  assert.equal(replay.status, 403);
  assert.equal(ctx.bridge.calls.has('c2'), false);
});

test('nonces survive a restart', async () => {
  const one = await startBridge();
  const r = await webhook(one, '/hangup', { CallUUID: 'none' });
  assert.equal(r.status, 200);
  await one.stop();
  const two = await startBridge({ stateFile: one.stateFile });
  try {
    const replay = await webhook(two, '/hangup', { CallUUID: 'none' }, { sign: false, headers: r.headers });
    assert.equal(replay.status, 403);
  } finally {
    await two.stop();
  }
});

test('Dial callbacks carry the call id in the signed path; a captured signature cannot steer another call', async (t) => {
  const ctx = await startBridge(RINGS_ALICE);
  t.after(ctx.stop);
  const a = await answerCall(ctx, { CallUUID: 'call-A', From: '+919800000001', To: '+918000000000' });
  const b = await answerCall(ctx, { CallUUID: 'call-B', From: '+919800000002', To: '+918000000000' });
  const actionA = new URL(`${PUBLIC_URL}${a.action}`);
  const actionB = new URL(`${PUBLIC_URL}${b.action}`);
  assert.doesNotMatch(a.text, /dial-result\/[^"]*\?/, 'no unsigned query string');
  assert.match(actionA.pathname, /^\/dial-result\/call-A\.[\w-]{22}$/);

  // Vobiz's genuine signature for call A's action URL, sent to call B's.
  const sigA = signV3(`${PUBLIC_URL}${actionA.pathname}`);
  const steer = await webhook(ctx, actionB.pathname, { DialStatus: 'cancel' }, { sign: false, headers: sigA });
  assert.equal(steer.status, 403);
  assert.equal(ctx.bridge.calls.get('call-B').finished, null);

  // A made-up path for call B (no valid tag) does nothing even when signed.
  const forged = await webhook(ctx, '/dial-result/call-B.AAAAAAAAAAAAAAAAAAAAAA', { DialStatus: 'cancel' });
  assert.equal(forged.status, 200);
  assert.match(forged.text, /<Hangup\/>/);
  assert.equal(ctx.bridge.calls.get('call-B').finished, null);
});
