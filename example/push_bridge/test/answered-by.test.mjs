// An inbound call rings several SIP users. Once Vobiz says which of them
// answered, only that user's app may act on the call: the connection watch,
// a conference, and whether the user counts as busy.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { answerCall, appAuth, postJson, startBridge, webhook } from './helpers.mjs';

const CALL = '11111111-2222-4333-8444-555555555555';
const NUMBER = '+918000000001';
const FAST = { lostBeepMs: 60000, lostHangupMs: 0, watchTickMs: 20 };

async function answeredBy(user, { deps = FAST } = {}) {
  const ctx = await startBridge({
    env: { ROUTES: `${NUMBER}=alice,bob`, VOBIZ_NUMBER: NUMBER },
    apiHandler: (method, pathname) => (method === 'POST' && pathname === '/Call/' ? { request_uuid: 'r1' } : { message: 'ok' }),
    deps,
  });
  const call = await answerCall(ctx, { CallUUID: CALL, From: '+919800000001', To: NUMBER });
  await webhook(ctx, call.events, { Event: 'DialAnswer', DialAction: 'answer', DialBLegTo: `sip:${user}@registrar.vobiz.ai` });
  return { ctx, call };
}

test('only the user who answered may have the call watched', async (t) => {
  const { ctx } = await answeredBy('bob');
  t.after(ctx.stop);
  assert.equal((await postJson(ctx, '/call/alive', { call_uuid: CALL }, appAuth('alice'))).status, 403, 'alice was rung, but bob answered');
  assert.equal((await postJson(ctx, '/call/alive', { call_uuid: CALL }, appAuth('bob'))).status, 200);
  assert.equal((await postJson(ctx, '/call/alive', { call_uuid: CALL }, appAuth('BOB'))).status, 403, 'the watch is bob\'s');
});

test('only the user who answered may turn the call into a conference, and an operator\'s room is that user\'s', async (t) => {
  const { ctx } = await answeredBy('bob');
  t.after(ctx.stop);
  const body = { call_uuid: CALL, number: '+919811111111' };
  assert.equal((await postJson(ctx, '/conference/add', body, appAuth('alice'))).status, 403);

  const opened = await postJson(ctx, '/conference/add', body, appAuth());
  assert.equal(opened.status, 200, opened.text);
  assert.equal(opened.json.participants[0].label, 'bob', 'the host is the user who answered, not the first one rung');
  assert.equal((await postJson(ctx, '/conference/state', { call_uuid: CALL }, appAuth('bob'))).status, 200);
  assert.equal((await postJson(ctx, '/conference/state', { call_uuid: CALL }, appAuth('alice'))).status, 403);
});

test('while it rings, any user rung may report; Vobiz naming no user keeps that', async (t) => {
  const ctx = await startBridge({ env: { ROUTES: `${NUMBER}=alice,bob,+919800000099` }, deps: FAST });
  t.after(ctx.stop);
  const call = await answerCall(ctx, { CallUUID: CALL, From: '+919800000001', To: NUMBER });
  assert.equal((await postJson(ctx, '/call/alive', { call_uuid: CALL }, appAuth('alice'))).status, 200, 'the answer event may come after the first report');
  await webhook(ctx, call.events, { Event: 'DialAnswer', DialAction: 'answer', DialBLegTo: '+919800000099' });
  assert.equal(ctx.bridge.calls.get(CALL).answeredBy, null, 'a phone number answered: no SIP user to hold to');
});

test('a user rung but not answering is not busy for the next call', async (t) => {
  const { ctx } = await answeredBy('bob');
  t.after(ctx.stop);
  const second = await answerCall(ctx, { CallUUID: 'c2', From: '+919800000002', To: NUMBER });
  const result = await webhook(ctx, second.action, { DialStatus: 'busy' });
  assert.doesNotMatch(result.text, /busy\.wav/, 'alice is free, so busy is not "everyone is on a call"');
  assert.equal(ctx.bridge.calls.get('c2').lineBusy, false);
});
