// #31: Decline acts at once and the caller hears busy, whether or not the
// caller's leg was already answered by an earlier <Dial>.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { answerCall, postJson, registerDevice, startBridge, until, webhook } from './helpers.mjs';

async function ringingCall(ctx, id = 'c1') {
  await registerDevice(ctx, 'alice');
  const { action } = await answerCall(ctx, { CallUUID: id, From: '+919800000001', To: '+918000000001' });
  const push = await until(() => ctx.pushes.find((p) => p.data.type === 'incoming_call'));
  return { action, push };
}

const BUSY = /<PreAnswer><Play>[^<]*\/busy\.wav<\/Play><\/PreAnswer>\s*<Hangup reason="busy"\/>/;

test('busy.wav is served (3 s of 8 kHz audio)', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const wav = await fetch(`${ctx.base}/busy.wav`);
  assert.equal(wav.status, 200);
  assert.equal((await wav.arrayBuffer()).byteLength, 44 + 8000 * 3 * 2);
});

test('Decline transfers the caller to busy immediately and stops the other phones', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const { push } = await ringingCall(ctx);
  const r = await postJson(ctx, '/push/decline', { call_id: push.data.call_id, call_key: push.data.call_key });
  assert.equal(r.status, 200);
  assert.equal(r.json.busy, 'transferred');

  const transfer = ctx.api.find((c) => c.pathname === '/Call/c1/');
  assert.equal(transfer.body.legs, 'aleg');
  const target = new URL(transfer.body.aleg_url);
  assert.match(target.pathname, /^\/declined\/c1\.[\w-]{22}$/);
  const xml = await webhook(ctx, target.pathname, { CallUUID: 'c1' });
  assert.match(xml.text, BUSY);

  const ended = await until(() => ctx.pushes.find((p) => p.data.type === 'call_ended'));
  assert.equal(ended.data.reason, 'declined');
});

test('a dial result after Decline plays busy (not a bare Hangup) even if the transfer failed', async (t) => {
  const ctx = await startBridge({
    apiHandler: (method, pathname) => {
      if (pathname.startsWith('/Call/')) throw new Error('404');
      return { objects: [{ username: 'alice' }], meta: { total_count: 1 } };
    },
  });
  t.after(ctx.stop);
  const { action, push } = await ringingCall(ctx);
  const r = await postJson(ctx, '/push/decline', { call_id: push.data.call_id, call_key: push.data.call_key });
  assert.equal(r.json.busy, 'next_attempt');
  const next = await webhook(ctx, action, { DialStatus: 'busy' });
  assert.match(next.text, BUSY);
});

test('a late Accept after Decline is told the call is over', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const { push } = await ringingCall(ctx);
  await postJson(ctx, '/push/decline', { call_id: push.data.call_id, call_key: push.data.call_key });
  const accept = await postJson(ctx, '/push/accept', { call_id: push.data.call_id, call_key: push.data.call_key });
  assert.equal(accept.json.finished, true);
});
