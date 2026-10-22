// #45 / #46 (bridge side): a second call while the endpoint is on a call is
// flagged as call waiting and not re-dialled for RING_SECONDS; every INVITE
// carries the exact call id the push carried.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { answerCall, registerDevice, startBridge, until, webhook, xmlAttr } from './helpers.mjs';

async function call(ctx, id) {
  return answerCall(ctx, { CallUUID: id, From: '+919800000001', To: '+918000000001' });
}

const incoming = (ctx, id) => until(() => ctx.pushes.find((p) => p.data.type === 'incoming_call' && p.data.call_id === id));

test('a second call while the endpoint is on a call is pushed as line_busy and ends busy at once', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  await registerDevice(ctx, 'alice');
  const first = await call(ctx, 'c1');
  assert.equal((await incoming(ctx, 'c1')).data.line_busy, undefined);
  await webhook(ctx, first.events, { Event: 'DialAnswer', DialAction: 'answer' });

  const second = await call(ctx, 'c2');
  assert.equal((await incoming(ctx, 'c2')).data.line_busy, '1');
  const result = await webhook(ctx, second.action, { DialStatus: 'busy' });
  assert.match(result.text, /<Hangup reason="busy"\/>/);
  assert.doesNotMatch(result.text, /<Dial/);
  assert.equal(ctx.bridge.calls.get('c2').finished, 'busy');
  const ended = await until(() => ctx.pushes.find((p) => p.data.type === 'call_ended' && p.data.call_id === 'c2'));
  assert.equal(ended.data.reason, 'busy');

  // After the first call ends, a new call is ordinary again.
  await webhook(ctx, '/hangup', { CallUUID: 'c1', CallStatus: 'completed' });
  await call(ctx, 'c3');
  assert.equal((await incoming(ctx, 'c3')).data.line_busy, undefined);
});

for (const style of ['suffix', 'plain']) {
  test(`every <User> in the Dial carries PushRef = the push's call_id (${style})`, async (t) => {
    const ctx = await startBridge({ env: { SIP_HEADER_STYLE: style, ROUTES: '+918000000001=alice,bob' } });
    t.after(ctx.stop);
    await registerDevice(ctx, 'alice');
    await registerDevice(ctx, 'bob');
    const first = await answerCall(ctx, { CallUUID: 'call-uuid-1', From: '+919800000001', To: '+918000000001' });
    const push = await incoming(ctx, 'call-uuid-1');
    const key = style === 'plain' ? 'PushRef' : 'PushRefX-VH';
    const ref = (xml) => xmlAttr(xml, 'User', 'sipHeaders').split(',').find((p) => p.startsWith(`${key}=`));
    const users = first.text.match(/<User [^>]*>/g);
    assert.equal(users.length, 2);
    for (const user of users) assert.equal(ref(user), `${key}=${push.data.call_id}`);
  });
}
