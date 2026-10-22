// #8: the caller waits on ringback (up to PUSH_WAIT_SECONDS) for the woken app
// to sign in, then everyone rings at once in ONE <Dial>: app endpoints,
// ALWAYS_RING endpoints and the route's PSTN numbers. The Dial is never
// restarted.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseRoutes } from '../push-bridge.mjs';
import {
  PUBLIC_URL, answerCall, postJson, registerDevice, startBridge, until, webhook, xmlAttr,
} from './helpers.mjs';

const ROUTES = '+918000000001=alice,+919800000099';
const CALL = { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' };

const incoming = (ctx, id = 'c1') => until(() => ctx.pushes.find((p) => p.data.type === 'incoming_call' && p.data.call_id === id));
const redirectPath = (xml) => new URL(xml.match(/<Redirect[^>]*>([^<]+)<\/Redirect>/)[1]).pathname;

test('/answer holds the caller on ringback (PreAnswer), then redirects to /dial-now', async (t) => {
  const ctx = await startBridge({ env: { ROUTES, ALWAYS_RING: 'browser1' } });
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  const r = await webhook(ctx, '/answer', CALL);
  assert.match(r.text, /^<\?xml[\s\S]*<Response>\n  <PreAnswer><Play>https:\/\/bridge\.example\.test\/wait\.wav<\/Play><\/PreAnswer>\n  <Redirect method="POST">/);
  assert.doesNotMatch(r.text, /<Dial/);
  assert.match(redirectPath(r.text), /^\/dial-now\/c1\.[\w-]{22}$/);
});

test('register within the wait: transferred at once to ONE Dial with every target', async (t) => {
  const ctx = await startBridge({ env: { ROUTES, ALWAYS_RING: 'browser1' } });
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  const started = Date.now();
  await webhook(ctx, '/answer', CALL);
  const push = await incoming(ctx);

  const r = await postJson(ctx, '/push/registered', { call_id: 'c1', call_key: push.data.call_key });
  assert.equal(r.json.redial, 'transferred');
  assert.equal(r.json.finished, false);
  assert.ok(Date.now() - started < 1500, 'did not wait for the window to end');
  const transfer = ctx.api.find((c) => c.pathname === '/Call/c1/');
  assert.equal(transfer.body.legs, 'aleg');
  const target = new URL(transfer.body.aleg_url);
  assert.equal(target.origin, PUBLIC_URL);
  assert.match(target.pathname, /^\/dial-now\/c1\.[\w-]{22}$/);

  const dial = await webhook(ctx, target.pathname, { CallUUID: 'c1' });
  assert.equal((dial.text.match(/<Dial[ >]/g) || []).length, 1);
  assert.match(dial.text, /<User sipHeaders="PushRefX-VH=c1,CallerX-VH=919800000001">sip:alice@registrar\.vobiz\.ai<\/User>/);
  assert.match(dial.text, /<User sipHeaders="PushRefX-VH=c1,[^"]*">sip:browser1@registrar\.vobiz\.ai<\/User>/);
  assert.match(dial.text, /<Number>\+919800000099<\/Number>/);
  assert.equal(xmlAttr(dial.text, 'Dial', 'timeout'), '45');
  assert.equal(xmlAttr(dial.text, 'Dial', 'callerId'), '+918000000001');
  assert.doesNotMatch(dial.text, /PreAnswer/);

  // A second "registered" (the same phone again) does not transfer twice.
  const again = await postJson(ctx, '/push/registered', { call_id: 'c1', call_key: push.data.call_key });
  assert.equal(again.json.redial, 'too_late');
  assert.equal(ctx.api.filter((c) => c.pathname === '/Call/c1/').length, 1);
});

test('two pushed phones: the Dial waits for both, then goes at once', async (t) => {
  const ctx = await startBridge({ env: { ROUTES: '+918000000001=alice,bob' } });
  t.after(ctx.stop);
  const alice = await registerDevice(ctx, 'alice');
  const bob = await registerDevice(ctx, 'bob');
  await webhook(ctx, '/answer', CALL);
  await until(() => ctx.pushes.filter((p) => p.data.type === 'incoming_call').length === 2);
  const first = await postJson(ctx, '/push/registered', {}, alice.auth);
  assert.deepEqual(first.json.calls, { c1: 'waiting' });
  assert.equal(ctx.api.filter((c) => c.pathname.startsWith('/Call/')).length, 0);
  const second = await postJson(ctx, '/push/registered', {}, bob.auth);
  assert.deepEqual(second.json.calls, { c1: 'transferred' });
});

test('no register: the wait ends, Vobiz follows the Redirect, and the Dial still has the browser and the Number', async (t) => {
  const ctx = await startBridge({ env: { ROUTES, ALWAYS_RING: 'browser1' } });
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  const call = await answerCall(ctx, CALL); // follows the Redirect, as at the end of wait.wav
  assert.ok(call.hold, 'held first');
  assert.equal(ctx.api.filter((c) => c.pathname.startsWith('/Call/')).length, 0, 'no transfer without a register');
  assert.match(call.text, /sip:browser1@/);
  assert.match(call.text, /<Number>\+919800000099<\/Number>/);
  // All routed users are in the Dial, registered in time or not: an open app
  // that did not report still rings; an offline one just fails its leg.
  assert.match(call.text, /sip:alice@/);
  assert.ok(ctx.bridge.calls.get('c1').dialStarted);
});

test('the wait length is PUSH_WAIT_SECONDS: default 5, clamped to 3..9', async (t) => {
  for (const [value, expected] of [[undefined, 5], ['1', 3], ['7', 7], ['10', 9], ['60', 9], ['nope', 5]]) {
    const ctx = await startBridge({ env: value === undefined ? {} : { PUSH_WAIT_SECONDS: value } });
    try {
      assert.equal(ctx.bridge.config.pushWaitSeconds, expected, `PUSH_WAIT_SECONDS=${value}`);
      const wav = await (await fetch(`${ctx.base}/wait.wav`)).arrayBuffer();
      assert.equal(wav.byteLength, 44 + 8000 * expected * 2);
      await registerDevice(ctx, 'alice');
      const before = Date.now();
      await webhook(ctx, '/answer', CALL);
      const call = ctx.bridge.calls.get('c1');
      assert.ok(Math.abs(call.waitUntil - before - expected * 1000) < 500);
    } finally {
      await ctx.stop();
    }
  }
});

test('nothing to wake (only ALWAYS_RING / PSTN, or no push token): dial at once, no hold', async (t) => {
  const ctx = await startBridge({ env: { ROUTES: '+918000000001=+919800000099', ALWAYS_RING: 'browser1' } });
  t.after(ctx.stop);
  const r = await webhook(ctx, '/answer', CALL);
  assert.doesNotMatch(r.text, /Redirect|PreAnswer/);
  assert.match(r.text, /<Dial[^>]*>\n    <User[^>]*>sip:browser1@registrar\.vobiz\.ai<\/User>\n    <Number>\+919800000099<\/Number>\n  <\/Dial>/);
});

test('late register (after the Dial started) does not restart it: too_late, then call_ended', async (t) => {
  const ctx = await startBridge({ env: { ROUTES, ALWAYS_RING: 'browser1' } });
  t.after(ctx.stop);
  const alice = await registerDevice(ctx, 'alice');
  const call = await answerCall(ctx, CALL);
  const push = await incoming(ctx);

  const late = await postJson(ctx, '/push/registered', { call_id: 'c1', call_key: push.data.call_key });
  assert.equal(late.status, 200);
  assert.deepEqual(late.json, { ok: true, redial: 'too_late', finished: false });
  assert.equal(ctx.api.filter((c) => c.pathname.startsWith('/Call/')).length, 0, 'no transfer: the ringing Dial is left alone');
  assert.deepEqual((await postJson(ctx, '/push/registered', {}, alice.auth)).json.calls, { c1: 'too_late' });

  // The browser answers: the late app's screen is closed by call_ended.
  await webhook(ctx, call.events, { Event: 'DialAnswer', DialAction: 'answer', DialBLegTo: 'sip:browser1@registrar.vobiz.ai' });
  const ended = await until(() => ctx.pushes.find((p) => p.data.type === 'call_ended'));
  assert.equal(ended.token, alice.fcm);
  assert.equal(ended.data.reason, 'answered_elsewhere');
  assert.equal(ended.data.answered_by, 'browser1');
});

test('late register, nobody answers: the Dial result ends the call (no second Dial) and pushes missed', async (t) => {
  const ctx = await startBridge({ env: { ROUTES } });
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  const call = await answerCall(ctx, CALL);
  const push = await incoming(ctx);
  await postJson(ctx, '/push/registered', { call_id: 'c1', call_key: push.data.call_key });
  const result = await webhook(ctx, call.action, { DialStatus: 'no-answer' });
  assert.doesNotMatch(result.text, /<Dial/);
  assert.match(result.text, /no answer[\s\S]*<Hangup\/>/);
  const ended = await until(() => ctx.pushes.find((p) => p.data.type === 'call_ended'));
  assert.equal(ended.data.reason, 'missed');
});

test('there is no re-dial loop: every unanswered Dial result ends the call', async (t) => {
  for (const status of ['failed', 'busy', 'no-answer', 'timeout', 'completed']) {
    const ctx = await startBridge();
    try {
      await registerDevice(ctx, 'alice');
      const call = await answerCall(ctx, CALL);
      const r = await webhook(ctx, call.action, { DialStatus: status });
      assert.doesNotMatch(r.text, /<Dial|<Redirect|PreAnswer/, `DialStatus=${status}`);
      assert.match(r.text, /<Hangup\/>/);
      assert.equal(ctx.bridge.calls.get('c1').finished, 'missed');
    } finally {
      await ctx.stop();
    }
  }
});

test('a register that arrives in the last second lets the Redirect dial (no racing transfer)', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  await webhook(ctx, '/answer', CALL);
  const push = await incoming(ctx);
  ctx.bridge.calls.get('c1').waitUntil = Date.now() + 500;
  const r = await postJson(ctx, '/push/registered', { call_id: 'c1', call_key: push.data.call_key });
  assert.equal(r.json.redial, 'waiting');
  assert.equal(ctx.api.filter((c) => c.pathname.startsWith('/Call/')).length, 0);
});

test('if the transfer fails, the reply is waiting and the Redirect still dials', async (t) => {
  const ctx = await startBridge({
    apiHandler: (method, pathname) => {
      if (pathname.startsWith('/Call/')) throw new Error('404 not in progress');
      return { objects: [{ username: 'alice' }], meta: { total_count: 1 } };
    },
  });
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  const hold = await webhook(ctx, '/answer', CALL);
  const push = await incoming(ctx);
  const r = await postJson(ctx, '/push/registered', { call_id: 'c1', call_key: push.data.call_key });
  assert.equal(r.json.redial, 'waiting');
  const dial = await webhook(ctx, redirectPath(hold.text), { CallUUID: 'c1' });
  assert.match(dial.text, /<Dial/);
});

test('Decline during the wait: the Redirect plays busy instead of dialling', async (t) => {
  const ctx = await startBridge({
    apiHandler: (method, pathname) => {
      if (pathname.startsWith('/Call/')) throw new Error('404');
      return { objects: [{ username: 'alice' }], meta: { total_count: 1 } };
    },
  });
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  const hold = await webhook(ctx, '/answer', CALL);
  const push = await incoming(ctx);
  await postJson(ctx, '/push/decline', { call_id: 'c1', call_key: push.data.call_key });
  const r = await webhook(ctx, redirectPath(hold.text), { CallUUID: 'c1' });
  assert.match(r.text, /<Hangup reason="busy"\/>/);
  assert.doesNotMatch(r.text, /<Dial/);
});

test('ROUTES: +digits entries become <Number>; old ROUTES still parse', () => {
  assert.deepEqual([...parseRoutes('+918000000001=alice,bob;8000000002=carol')], [
    ['+918000000001', { users: ['alice', 'bob'], numbers: [] }],
    ['+918000000002', { users: ['carol'], numbers: [] }],
  ]);
  assert.deepEqual([...parseRoutes('+918000000001=alice, +919876543210 ,bob,+919876543210;+918000000003=+14155550101')], [
    ['+918000000001', { users: ['alice', 'bob'], numbers: ['+919876543210'] }],
    ['+918000000003', { users: [], numbers: ['+14155550101'] }],
  ]);
  assert.equal(parseRoutes('').size, 0);
  assert.equal(parseRoutes('+918000000001=').size, 0);
});

test('the caller hears no Dial before the hold, even if the push is slow', async (t) => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const ctx = await startBridge({ pushDelay: () => gate });
  t.after(() => { release(); return ctx.stop(); });
  await registerDevice(ctx, 'alice');
  const started = Date.now();
  const r = await webhook(ctx, '/answer', CALL);
  assert.match(r.text, /<Redirect/);
  assert.ok(Date.now() - started < 1000, `took ${Date.now() - started} ms`);
});

test('"registered" needs the call key or the phone\'s device token', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  await webhook(ctx, '/answer', CALL);
  await incoming(ctx);
  assert.equal((await postJson(ctx, '/push/registered', { call_id: 'c1', call_key: 'wrong' })).status, 404);
  assert.equal((await postJson(ctx, '/push/registered', {})).status, 401);
});
