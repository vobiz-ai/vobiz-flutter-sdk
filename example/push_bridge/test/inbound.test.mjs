// An inbound call: /answer rings everyone ROUTES and ALWAYS_RING name, at
// once, in ONE <Dial>. The Dial is never restarted, and a Dial that ends
// without an answer ends the call.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseRoutes } from '../push-bridge.mjs';
import { answerCall, startBridge, webhook, xmlAttr } from './helpers.mjs';

const ROUTES = '+918000000001=alice,bob,+919800000099;+918000000002=carol';
const CALL = { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' };
const NO_ANSWER = /<Speak>Sorry, there was no answer\. Please try again later\.<\/Speak><Hangup\/>/;
const BUSY = /<PreAnswer><Play>[^<]*\/busy\.wav<\/Play><\/PreAnswer>\s*<Hangup reason="busy"\/>/;

test('/answer returns ONE Dial at once with every routed user, the ALWAYS_RING user and the number', async (t) => {
  const ctx = await startBridge({ env: { ROUTES, ALWAYS_RING: 'browser1' } });
  t.after(ctx.stop);
  const call = await answerCall(ctx, CALL);
  assert.equal((call.text.match(/<Dial[ >]/g) || []).length, 1);
  assert.doesNotMatch(call.text, /PreAnswer|Redirect/);
  assert.match(call.text, /<Dial[^>]*>\n    <User [^>]*>sip:alice@registrar\.vobiz\.ai<\/User>\n    <User [^>]*>sip:bob@registrar\.vobiz\.ai<\/User>\n    <User [^>]*>sip:browser1@registrar\.vobiz\.ai<\/User>\n    <Number>\+919800000099<\/Number>\n  <\/Dial>/);
  assert.equal(xmlAttr(call.text, 'Dial', 'timeout'), '45');
  assert.equal(xmlAttr(call.text, 'Dial', 'callerId'), '+918000000001', 'CALLER_ID_MODE=number: the dialled number');
  assert.match(call.action, /^\/dial-result\/c1\.[\w-]{22}$/);
  assert.match(call.events, /^\/dial-events\/c1\.[\w-]{22}$/);
});

test('only the dialled number\'s route is rung', async (t) => {
  const ctx = await startBridge({ env: { ROUTES } });
  t.after(ctx.stop);
  const call = await answerCall(ctx, { ...CALL, To: '918000000002' });
  assert.match(call.text, /sip:carol@/);
  assert.doesNotMatch(call.text, /sip:alice@|sip:bob@|<Number>/);
});

test('no ROUTES entry and no ALWAYS_RING: the caller is told, and no call is kept', async (t) => {
  const ctx = await startBridge({ env: { ROUTES: '+918000000002=carol' } });
  t.after(ctx.stop);
  const r = await webhook(ctx, '/answer', CALL);
  assert.match(r.text, /<Speak>[^<]+<\/Speak><Hangup\/>/);
  assert.doesNotMatch(r.text, /<Dial/);
  assert.equal(ctx.bridge.calls.size, 0);
  assert.ok(ctx.logs.some((l) => /no ROUTES entry/.test(l)));
});

test('Vobiz asking /answer again for the same call gets the same Dial', async (t) => {
  const ctx = await startBridge({ env: { ROUTES } });
  t.after(ctx.stop);
  const first = await answerCall(ctx, CALL);
  const again = await answerCall(ctx, CALL);
  assert.equal(again.text, first.text);
  assert.equal(ctx.bridge.calls.size, 1);
});

test('a DialAnswer event marks the call answered, and "completed" then hangs up', async (t) => {
  const ctx = await startBridge({ env: { ROUTES } });
  t.after(ctx.stop);
  const call = await answerCall(ctx, CALL);
  await webhook(ctx, call.events, { Event: 'DialAnswer', DialAction: 'answer', DialBLegTo: 'sip:bob@registrar.vobiz.ai' });
  const record = ctx.bridge.calls.get('c1');
  assert.equal(record.bridged, true);
  assert.equal(record.finished, 'answered');
  const result = await webhook(ctx, call.action, { DialStatus: 'completed' });
  assert.match(result.text, /<Response>\n<Hangup\/>\n<\/Response>/);
  assert.equal(record.over, true);
});

test('busy plays the busy tone only when everyone rung is on another call this server connected', async (t) => {
  const ctx = await startBridge({ env: { ROUTES: '+918000000001=alice' } });
  t.after(ctx.stop);
  const first = await answerCall(ctx, CALL);
  await webhook(ctx, first.events, { Event: 'DialAnswer', DialAction: 'answer' });

  // Alice is on c1: her app refuses c2 (486), and Vobiz reports busy.
  const second = await answerCall(ctx, { ...CALL, CallUUID: 'c2' });
  const busy = await webhook(ctx, second.action, { DialStatus: 'busy' });
  assert.match(busy.text, BUSY);
  assert.doesNotMatch(busy.text, /<Dial/);
  assert.equal(ctx.bridge.calls.get('c2').finished, 'busy');

  // After c1 ends, busy is not proof of anything: Vobiz also says busy for a
  // SIP user it could not reach. The caller hears "no answer".
  await webhook(ctx, '/hangup', { CallUUID: 'c1', CallStatus: 'completed' });
  const third = await answerCall(ctx, { ...CALL, CallUUID: 'c3' });
  const notBusy = await webhook(ctx, third.action, { DialStatus: 'busy', DialHangupCause: 'USER_BUSY' });
  assert.match(notBusy.text, NO_ANSWER);
  assert.equal(ctx.bridge.calls.get('c3').finished, 'missed');
});

test('there is no re-dial: every unanswered Dial result ends the call with "no answer"', async () => {
  for (const status of ['failed', 'busy', 'no-answer', 'timeout', 'completed', '']) {
    const ctx = await startBridge({ env: { ROUTES } });
    try {
      const call = await answerCall(ctx, CALL);
      const r = await webhook(ctx, call.action, { DialStatus: status });
      assert.doesNotMatch(r.text, /<Dial|<Redirect|PreAnswer/, `DialStatus=${status}`);
      assert.match(r.text, NO_ANSWER, `DialStatus=${status}`);
      assert.equal(ctx.bridge.calls.get('c1').finished, 'missed');
    } finally {
      await ctx.stop();
    }
  }
});

test('the caller hanging up while it rings ends the call quietly', async (t) => {
  const ctx = await startBridge({ env: { ROUTES } });
  t.after(ctx.stop);
  const call = await answerCall(ctx, CALL);
  const r = await webhook(ctx, call.action, { DialStatus: 'cancel' });
  assert.match(r.text, /<Response>\n<Hangup\/>\n<\/Response>/);
  assert.equal(ctx.bridge.calls.get('c1').finished, 'caller hung up');
  assert.equal((await webhook(ctx, '/hangup', { CallUUID: 'c1', CallStatus: 'completed' })).status, 200);
  assert.equal(ctx.bridge.calls.get('c1').over, true);
});

for (const style of ['suffix', 'plain']) {
  test(`every <User> carries PushRef = the call's CallUUID and the real caller (${style})`, async (t) => {
    const ctx = await startBridge({ env: { SIP_HEADER_STYLE: style, ROUTES: '+918000000001=alice,bob', ALWAYS_RING: 'browser1' } });
    t.after(ctx.stop);
    const call = await answerCall(ctx, { CallUUID: 'call-uuid-1', From: '+919800000001', To: '+918000000001' });
    const suffix = style === 'plain' ? '' : 'X-VH';
    const users = call.text.match(/<User [^>]*>/g);
    assert.equal(users.length, 3);
    for (const user of users) {
      assert.equal(xmlAttr(user, 'User', 'sipHeaders'), `PushRef${suffix}=call-uuid-1,Caller${suffix}=919800000001`);
    }
  });
}

test('a caller that is not a phone number gets no Caller header (no made-up number in the app)', async (t) => {
  const ctx = await startBridge({ env: { SIP_HEADER_STYLE: 'plain', ROUTES: '+918000000001=alice' } });
  t.after(ctx.stop);
  const callers = [
    'sip:12345678901234567@203.0.113.7', // a SIP user whose name is 17 digits
    'sip:agent42_MA_TEST0001@registrar.vobiz.ai', // a SIP user with digits in its name
    '1001', // a PBX extension
  ];
  for (const [i, from] of callers.entries()) {
    const call = await answerCall(ctx, { CallUUID: `sip-caller-${i}`, From: from, To: '+918000000001' });
    const user = call.text.match(/<User [^>]*>/)[0];
    assert.equal(xmlAttr(user, 'User', 'sipHeaders'), `PushRef=sip-caller-${i}`, from);
  }
  // A national number still counts: 10 digits are read as an Indian number.
  const call = await answerCall(ctx, { CallUUID: 'national', From: '9800000001', To: '+918000000001' });
  assert.equal(xmlAttr(call.text.match(/<User [^>]*>/)[0], 'User', 'sipHeaders'), 'PushRef=national,Caller=919800000001');
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
