// #9: when another phone (or ALWAYS_RING endpoint) answers, or the caller
// hangs up, every pushed phone is told at once so it stops ringing.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { answerCall, postJson, registerDevice, startBridge, until, webhook } from './helpers.mjs';

async function ringingCall(ctx, env) {
  const a = await registerDevice(ctx, 'alice', { name: 'phone-a' });
  const b = await registerDevice(ctx, 'alice', { name: 'phone-b' });
  const { events, action } = await answerCall(ctx, { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' });
  const push = await until(() => ctx.pushes.filter((p) => p.data.type === 'incoming_call').length === 2 && ctx.pushes[0]);
  return { a, b, events, action, push, env };
}

test('DialAnswer pushes call_ended{answered_elsewhere} to every pushed phone at once', async (t) => {
  const ctx = await startBridge({ env: { ALWAYS_RING: 'deskphone' } });
  t.after(ctx.stop);
  const { a, b, events } = await ringingCall(ctx);
  const r = await webhook(ctx, events, { Event: 'DialAnswer', DialAction: 'answer', DialBLegTo: 'sip:deskphone@registrar.vobiz.ai' });
  assert.equal(r.status, 200);
  const ended = await until(() => {
    const list = ctx.pushes.filter((p) => p.data.type === 'call_ended');
    return list.length === 2 && list;
  });
  assert.deepEqual(ended.map((p) => p.token).sort(), [a.fcm, b.fcm].sort());
  for (const p of ended) {
    assert.equal(p.data.reason, 'answered_elsewhere');
    assert.equal(p.data.answered_by, 'deskphone');
    assert.equal(p.data.call_id, 'c1');
  }
  assert.equal(ctx.bridge.calls.get('c1').finished, 'answered');
});

test('a late Accept after another phone answered is told it is finished, and why', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const { events, push } = await ringingCall(ctx);
  await webhook(ctx, events, { Event: 'DialAnswer', DialAction: 'answer' });
  const accept = await postJson(ctx, '/push/accept', { call_id: push.data.call_id, call_key: push.data.call_key });
  assert.equal(accept.json.finished, true);
  assert.equal(accept.json.reason, 'answered_elsewhere');
});

test('the caller hanging up pushes call_ended{caller_hung_up} once', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const { action } = await ringingCall(ctx);
  await webhook(ctx, action, { DialStatus: 'cancel' });
  await webhook(ctx, '/hangup', { CallUUID: 'c1', CallStatus: 'completed' });
  const ended = await until(() => ctx.pushes.filter((p) => p.data.type === 'call_ended').length === 2
    && ctx.pushes.filter((p) => p.data.type === 'call_ended'));
  assert.ok(ended.every((p) => p.data.reason === 'caller_hung_up'));
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(ctx.pushes.filter((p) => p.data.type === 'call_ended').length, 2, 'not sent twice');
});
