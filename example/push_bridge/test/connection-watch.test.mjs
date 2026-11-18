// The connection watch: when the app stops reporting "alive" during a call,
// the other party hears a beep (Vobiz Play API); it stops when the app is
// back, and the call is ended once the app is past its reconnect window.
import assert from 'node:assert/strict';
import test from 'node:test';
import { postJson, registerDevice, sleep, startBridge, until } from './helpers.mjs';

const UUID = '11111111-2222-4333-8444-555555555555';
const FAST = { lostBeepMs: 150, lostHangupMs: 900, watchTickMs: 20 };

/** A fake Vobiz API where call UUID is a live call placed by `owner`. */
function vobiz(owner) {
  return (method, pathname) => {
    if (pathname.startsWith('/Endpoint/')) {
      return { objects: ['alice', 'bob'].map((username) => ({ username })), meta: { total_count: 2 } };
    }
    if (method === 'GET' && pathname === `/Call/${UUID}/?status=live`) {
      return { call_uuid: UUID, call_status: 'in-progress', direction: 'inbound', from: `sip:${owner}@registrar.vobiz.ai`, to: '919876543210' };
    }
    return { message: 'ok' };
  };
}

const find = (ctx, method, pathname) => ctx.api.filter((c) => c.method === method && c.pathname === pathname);

test('the other party hears a beep while the app is silent, and it stops when the app is back', async () => {
  const ctx = await startBridge({ apiHandler: vobiz('alice'), deps: { ...FAST, lostHangupMs: 0 } });
  try {
    const alice = await registerDevice(ctx, 'alice');
    assert.equal((await postJson(ctx, '/call/alive', { call_uuid: UUID }, alice.auth)).status, 200);

    const play = await until(() => find(ctx, 'POST', `/Call/${UUID}/Play/`)[0], 2000);
    assert.ok(play, 'the beep was played');
    assert.equal(play.body.legs, 'bleg', 'to the callee: the app placed the call');
    assert.equal(play.body.loop, true);
    assert.match(play.body.urls, /\/lost\.wav$/);
    await sleep(200);
    assert.equal(find(ctx, 'POST', `/Call/${UUID}/Play/`).length, 1, 'played once, looped by Vobiz');

    assert.equal((await postJson(ctx, '/call/alive', { call_uuid: UUID }, alice.auth)).status, 200);
    assert.ok(await until(() => find(ctx, 'DELETE', `/Call/${UUID}/Play/`)[0], 2000), 'the beep stopped');
  } finally {
    await ctx.stop();
  }
});

test('an app that stays away past its reconnect window gets its call ended', async () => {
  const ctx = await startBridge({ apiHandler: vobiz('alice'), deps: FAST });
  try {
    const alice = await registerDevice(ctx, 'alice');
    const started = Date.now();
    await postJson(ctx, '/call/alive', { call_uuid: UUID }, alice.auth);
    const hangup = await until(() => find(ctx, 'DELETE', `/Call/${UUID}/`)[0], 3000);
    assert.ok(hangup, 'the call was ended');
    assert.ok(Date.now() - started >= FAST.lostHangupMs, 'not before the window passed');
    assert.ok(ctx.logs.some((l) => /not billed on/.test(l)));
  } finally {
    await ctx.stop();
  }
});

test('a phone cannot make the bridge act on a call that is not its own', async () => {
  const ctx = await startBridge({ apiHandler: vobiz('alice'), deps: FAST });
  try {
    const bob = await registerDevice(ctx, 'bob');
    const r = await postJson(ctx, '/call/alive', { call_uuid: UUID }, bob.auth);
    assert.equal(r.status, 403);
    assert.equal((await postJson(ctx, '/call/alive', { call_uuid: UUID })).status, 401, 'no device token');
    assert.equal((await postJson(ctx, '/call/alive', { call_uuid: 'not-a-uuid' }, bob.auth)).status, 400);
    await sleep(FAST.lostHangupMs + 200);
    assert.equal(ctx.api.filter((c) => c.method !== 'GET' && c.pathname.startsWith('/Call/')).length, 0, 'no beep, no hangup');
  } finally {
    await ctx.stop();
  }
});

test('a call the app reports ended is no longer watched', async () => {
  const ctx = await startBridge({ apiHandler: vobiz('alice'), deps: FAST });
  try {
    const alice = await registerDevice(ctx, 'alice');
    await postJson(ctx, '/call/alive', { call_uuid: UUID }, alice.auth);
    assert.equal((await postJson(ctx, '/call/ended', { call_uuid: UUID }, alice.auth)).status, 200);
    await sleep(FAST.lostHangupMs + 200);
    assert.equal(find(ctx, 'POST', `/Call/${UUID}/Play/`).length, 0);
    assert.equal(find(ctx, 'DELETE', `/Call/${UUID}/`).length, 0);
  } finally {
    await ctx.stop();
  }
});
