// Conference: the app's call moves into a room, people are dialled in and
// managed, and the room ends when only the app is left or the app leaves.
// A fake Vobiz API stands in for the REST calls; webhooks are signed as
// Vobiz signs them.
import assert from 'node:assert/strict';
import test from 'node:test';
import { BRIDGE_KEY, answerCall, appAuth, postJson, sleep, startBridge, until, webhook, xmlAttr } from './helpers.mjs';

const CALL = '11111111-2222-4333-8444-555555555555';
const GUEST_LEG = '22222222-2222-4333-8444-555555555555';
const ADDED = '33333333-2222-4333-8444-555555555555';
const ADDED_2 = '44444444-2222-4333-8444-555555555555';
const CALLER_ID = '+919800000001';

/**
 * A fake Vobiz API: CALL is a live call alice placed to +919876543210, and
 * each POST /Call/ places a call with the next of `placed`.
 */
function vobiz({ owner = 'alice', placed = [ADDED, ADDED_2] } = {}) {
  const queue = [...placed];
  return (method, pathname) => {
    if (method === 'GET' && pathname === `/Call/${CALL}/?status=live`) {
      return { call_uuid: CALL, call_status: 'in-progress', from: `sip:${owner}@registrar.vobiz.ai`, to: '919876543210' };
    }
    if (method === 'POST' && pathname === '/Call/') {
      return { message: 'call fired', request_uuid: queue.shift(), api_id: 'x' };
    }
    return { message: 'ok' };
  };
}

const calls = (ctx, method, pathname) => ctx.api.filter((c) => c.method === method && c.pathname === pathname);
const pathOf = (url) => new URL(url).pathname;

/** Alice's app turns call CALL into a conference by adding +919811111111. */
async function startConference({ env = { VOBIZ_NUMBER: CALLER_ID }, owner, placed } = {}) {
  const ctx = await startBridge({ env, apiHandler: vobiz({ owner, placed }) });
  const alice = appAuth('alice');
  const added = await postJson(ctx, '/conference/add', { call_uuid: CALL, number: '+919811111111', caller_id: CALLER_ID }, alice);
  const move = calls(ctx, 'POST', `/Call/${CALL}/`)[0];
  const dial = calls(ctx, 'POST', '/Call/')[0];
  return { ctx, alice, added, move, dial };
}

/** Vobiz asks for each leg's room XML, then reports every leg entering. Returns { host, guest, added } XML. */
async function everyoneJoins(c) {
  const host = await webhook(c.ctx, pathOf(c.move.body.aleg_url), { CallUUID: CALL, CallStatus: 'in-progress' });
  const guest = await webhook(c.ctx, pathOf(c.move.body.bleg_url), { CallUUID: GUEST_LEG, CallStatus: 'in-progress' });
  const added = await webhook(c.ctx, pathOf(c.dial.body.answer_url), { CallUUID: ADDED, To: '919811111111', CallStatus: 'in-progress' });
  const events = pathOf(xmlAttr(host.text, 'Conference', 'callbackUrl'));
  const room = c.added.json.room;
  let id = 10;
  for (const uuid of [CALL, GUEST_LEG, ADDED]) {
    await webhook(c.ctx, events, { ConferenceAction: 'enter', ConferenceName: room, ConferenceMemberID: String(id++), CallUUID: uuid });
  }
  return { host, guest, added, events, room };
}

async function state(c) {
  return (await postJson(c.ctx, '/conference/state', { call_uuid: CALL }, c.alice)).json;
}

const byRole = (s, role) => s.participants.find((p) => p.role === role);

test('add moves both sides of the call into a room and dials the new person into it', async () => {
  const c = await startConference();
  try {
    assert.equal(c.added.status, 200, c.added.text);
    assert.ok(c.move, 'the call was transferred');
    assert.equal(c.move.body.legs, 'both');
    assert.match(c.move.body.aleg_url, /\/conf-room\/vc-11111111-[0-9a-f]{6}\.host\./, 'the app placed the call: its A-leg is the host');
    assert.match(c.move.body.bleg_url, /\.guest\./);
    assert.equal(c.dial.body.from, CALLER_ID);
    assert.equal(c.dial.body.to, '+919811111111');
    assert.match(c.dial.body.answer_url, /\/conf-room\/.*\.added\./);
    assert.match(c.dial.body.hangup_url, /\/conf-dial\//);

    const s = c.added.json;
    assert.equal(s.active, true);
    assert.deepEqual(s.participants.map((p) => [p.role, p.status, p.you]), [
      ['host', 'connecting', true], ['guest', 'connecting', false], ['added', 'dialing', false],
    ]);
    assert.equal(byRole(s, 'guest').label, '+919876543210');

    const xml = await everyoneJoins(c);
    assert.equal(xmlAttr(xml.host.text, 'Conference', 'stayAlone'), 'true', 'nobody is dropped for being alone');
    assert.equal(xmlAttr(xml.host.text, 'Conference', 'endConferenceOnExit'), 'true', 'the room ends when the app leaves');
    assert.equal(xmlAttr(xml.guest.text, 'Conference', 'endConferenceOnExit'), 'false');
    assert.ok(xml.added.text.includes(`>${xml.room}</Conference>`), 'every leg joins the same room');
    assert.deepEqual((await state(c)).participants.map((p) => p.status), ['joined', 'joined', 'joined']);
  } finally {
    await c.ctx.stop();
  }
});

test('mute, hold, resume and remove act on the right member', async () => {
  const c = await startConference();
  try {
    const { events, room } = await everyoneJoins(c);
    const person = byRole(await state(c), 'added');
    const act = (action) => postJson(c.ctx, '/conference/participant', { call_uuid: CALL, participant_id: person.id, action }, c.alice);

    assert.equal((await act('mute')).status, 200);
    assert.equal(calls(c.ctx, 'POST', `/Conference/${room}/Member/12/Mute/`).length, 1);
    assert.equal(byRole(await state(c), 'added').muted, true);

    // Hold: out of the room onto looping music.
    assert.equal((await act('hold')).status, 200);
    const hold = calls(c.ctx, 'POST', `/Call/${ADDED}/`)[0];
    assert.equal(hold.body.legs, 'aleg');
    const holdXml = await webhook(c.ctx, pathOf(hold.body.aleg_url), { CallUUID: ADDED, CallStatus: 'in-progress' });
    assert.match(holdXml.text, /<Play loop="0">https:\/\/bridge\.example\.test\/hold\.wav<\/Play>/);
    await webhook(c.ctx, events, { ConferenceAction: 'exit', ConferenceName: room, ConferenceMemberID: '12', CallUUID: ADDED });
    assert.equal(byRole(await state(c), 'added').status, 'on_hold');
    assert.equal(calls(c.ctx, 'DELETE', `/Conference/${room}/`).length, 0, 'someone on hold keeps the room open');

    // Resume: back into the room, as a new member, muted again.
    assert.equal((await act('resume')).status, 200);
    const back = calls(c.ctx, 'POST', `/Call/${ADDED}/`)[1];
    assert.match(back.body.aleg_url, /\.added\./);
    await webhook(c.ctx, pathOf(back.body.aleg_url), { CallUUID: ADDED, CallStatus: 'in-progress' });
    await webhook(c.ctx, events, { ConferenceAction: 'enter', ConferenceName: room, ConferenceMemberID: '21', CallUUID: ADDED });
    assert.equal(byRole(await state(c), 'added').status, 'joined');
    assert.ok(await until(() => calls(c.ctx, 'POST', `/Conference/${room}/Member/21/Mute/`)[0], 2000), 'muted again after hold');

    assert.equal((await act('remove')).status, 200);
    assert.equal(calls(c.ctx, 'DELETE', `/Conference/${room}/Member/21/`).length, 1);
    const removed = byRole(await state(c), 'added');
    assert.equal(removed.status, 'left');
    assert.equal(removed.reason, 'removed');

    assert.equal((await act('mute')).status, 409, 'nobody to mute any more');
    assert.equal((await postJson(c.ctx, '/conference/participant', { call_uuid: CALL, participant_id: byRole(await state(c), 'host').id, action: 'mute' }, c.alice)).status, 400, 'the app is not a participant to manage');
  } finally {
    await c.ctx.stop();
  }
});

test('the room ends when only the app is left', async () => {
  const c = await startConference();
  try {
    const { events, room } = await everyoneJoins(c);
    await webhook(c.ctx, events, { ConferenceAction: 'exit', ConferenceName: room, ConferenceMemberID: '11', CallUUID: GUEST_LEG });
    assert.equal(calls(c.ctx, 'DELETE', `/Conference/${room}/`).length, 0, 'two people are still talking');
    await webhook(c.ctx, events, { ConferenceAction: 'exit', ConferenceName: room, ConferenceMemberID: '12', CallUUID: ADDED });
    assert.equal(calls(c.ctx, 'DELETE', `/Conference/${room}/`).length, 1, 'the app alone: the room ends');
    const s = await state(c);
    assert.equal(s.active, false);
    assert.equal(s.ended_reason, 'everyone else left');
  } finally {
    await c.ctx.stop();
  }
});

test('a person who does not answer is shown as not joined, and the call goes on', async () => {
  const c = await startConference();
  try {
    const { room } = await everyoneJoins(c);
    const second = await postJson(c.ctx, '/conference/add', { call_uuid: CALL, number: '+919822222222', caller_id: CALLER_ID }, c.alice);
    assert.equal(second.status, 200);
    assert.equal(calls(c.ctx, 'POST', `/Call/${CALL}/`).length, 1, 'already a conference: not moved again');
    const hangup = calls(c.ctx, 'POST', '/Call/')[1].body.hangup_url;
    await webhook(c.ctx, pathOf(hangup), { CallUUID: ADDED_2, RequestUUID: ADDED_2, CallStatus: 'busy', HangupCause: 'USER_BUSY' });
    const s = await state(c);
    const failed = s.participants.find((p) => p.label === '+919822222222');
    assert.equal(failed.status, 'failed');
    assert.equal(failed.reason, 'busy');
    assert.equal(s.active, true);
    assert.equal(calls(c.ctx, 'DELETE', `/Conference/${room}/`).length, 0);
  } finally {
    await c.ctx.stop();
  }
});

test('when the app leaves, the room ends and people on hold are hung up', async () => {
  const c = await startConference();
  try {
    const { events, room } = await everyoneJoins(c);
    const person = byRole(await state(c), 'added');
    await postJson(c.ctx, '/conference/participant', { call_uuid: CALL, participant_id: person.id, action: 'hold' }, c.alice);
    await webhook(c.ctx, events, { ConferenceAction: 'exit', ConferenceName: room, ConferenceMemberID: '12', CallUUID: ADDED });
    await webhook(c.ctx, events, { ConferenceAction: 'exit', ConferenceName: room, ConferenceMemberID: '10', CallUUID: CALL });
    assert.equal((await state(c)).active, false);
    assert.equal(calls(c.ctx, 'DELETE', `/Call/${ADDED}/`).length, 1, 'the person on hold was hung up');
  } finally {
    await c.ctx.stop();
  }
});

test('end hangs up the room for everyone', async () => {
  const c = await startConference();
  try {
    const { room } = await everyoneJoins(c);
    const ended = await postJson(c.ctx, '/conference/end', { call_uuid: CALL }, c.alice);
    assert.equal(ended.status, 200);
    assert.equal(ended.json.active, false);
    assert.equal(calls(c.ctx, 'DELETE', `/Conference/${room}/`).length, 1);
  } finally {
    await c.ctx.stop();
  }
});

test('an app can only turn its own SIP user\'s call into a conference', async () => {
  const ctx = await startBridge({ env: { VOBIZ_NUMBER: CALLER_ID }, apiHandler: vobiz({ owner: 'alice' }) });
  try {
    const bob = appAuth('bob');
    const body = { call_uuid: CALL, number: '+919811111111' };
    assert.equal((await postJson(ctx, '/conference/add', body)).status, 401, 'no credential');
    assert.equal((await postJson(ctx, '/conference/add', body, { Authorization: 'Bearer abc.def' })).status, 401, 'device tokens are gone');
    assert.equal((await postJson(ctx, '/conference/add', body, bob)).status, 403, 'bob is not on alice\'s call');
    assert.equal(ctx.api.filter((c) => c.method === 'POST').length, 0, 'nothing was moved or dialled');

    const alice = appAuth('alice');
    const ok = await postJson(ctx, '/conference/add', body, alice);
    assert.equal(ok.status, 200);
    assert.equal(ok.json.participants[2].label, '+919811111111');
    assert.equal(calls(ctx, 'POST', '/Call/')[0].body.from, CALLER_ID, 'VOBIZ_NUMBER is the default caller ID');
    assert.equal((await postJson(ctx, '/conference/state', { call_uuid: CALL }, bob)).status, 403, 'bob cannot read it either');
  } finally {
    await ctx.stop();
  }
});

test('VOBIZ_NUMBER written without its + is still the default caller ID', async () => {
  const ctx = await startBridge({ env: { VOBIZ_NUMBER: ' 919800000001 ' }, apiHandler: vobiz({ owner: 'alice' }) });
  try {
    assert.equal(ctx.bridge.config.number, CALLER_ID);
    const ok = await postJson(ctx, '/conference/add', { call_uuid: CALL, number: '+919811111111' }, appAuth('alice'));
    assert.equal(ok.status, 200, ok.text);
    assert.equal(calls(ctx, 'POST', '/Call/')[0].body.from, CALLER_ID);
  } finally {
    await ctx.stop();
  }
});

test('the bridge key may manage any live call; bad input is refused', async () => {
  const ctx = await startBridge({ apiHandler: vobiz() });
  try {
    const key = { 'X-Bridge-Key': BRIDGE_KEY };
    assert.equal((await postJson(ctx, '/conference/add', { call_uuid: 'nope', number: '+919811111111', caller_id: CALLER_ID }, key)).status, 400);
    assert.equal((await postJson(ctx, '/conference/add', { call_uuid: CALL, number: '98111', caller_id: CALLER_ID }, key)).status, 400);
    assert.equal((await postJson(ctx, '/conference/add', { call_uuid: CALL, number: '+919811111111' }, key)).status, 400, 'no caller ID and no VOBIZ_NUMBER');
    const ok = await postJson(ctx, '/conference/add', { call_uuid: CALL, user: 'bob', caller_id: CALLER_ID, host_leg: 'bleg' }, key);
    assert.equal(ok.status, 200, ok.text);
    const move = calls(ctx, 'POST', `/Call/${CALL}/`)[0];
    assert.match(move.body.bleg_url, /\.host\./, 'host_leg chooses the host');
    assert.equal(calls(ctx, 'POST', '/Call/')[0].body.to, 'sip:bob@registrar.vobiz.ai', 'a SIP user is dialled by URI');
  } finally {
    await ctx.stop();
  }
});

test('an empty or malformed X-Bridge-User is refused, never treated as the key holder', async () => {
  const ctx = await startBridge({ env: { VOBIZ_NUMBER: CALLER_ID }, apiHandler: vobiz({ owner: 'alice' }) });
  try {
    const body = { call_uuid: CALL, number: '+919811111111', host_leg: 'bleg' };
    for (const user of ['', 'alice, bob', 'sip user']) {
      const r = await postJson(ctx, '/conference/add', body, appAuth(user));
      assert.equal(r.status, 400, `X-Bridge-User "${user}"`);
    }
    assert.equal((await postJson(ctx, '/conference/state', { call_uuid: CALL }, appAuth(''))).status, 400);
    assert.equal(ctx.api.length, 0, 'Vobiz was not even asked');
  } finally {
    await ctx.stop();
  }
});

test('an inbound call the bridge rang: the app is the B-leg and hosts', async () => {
  const ctx = await startBridge({ env: { VOBIZ_NUMBER: CALLER_ID, ROUTES: `${CALLER_ID}=alice` }, apiHandler: vobiz() });
  try {
    const alice = appAuth('alice');
    const call = await answerCall(ctx, { CallUUID: CALL, From: '+919876543210', To: CALLER_ID, CallStatus: 'ringing' });
    await webhook(ctx, call.events, { Event: 'DialAnswer', DialAction: 'answer', DialBLegTo: 'sip:alice@registrar.vobiz.ai' });
    const added = await postJson(ctx, '/conference/add', { call_uuid: CALL, number: '+919811111111' }, alice);
    assert.equal(added.status, 200, added.text);
    const move = calls(ctx, 'POST', `/Call/${CALL}/`).find((c) => c.body.legs === 'both');
    assert.match(move.body.bleg_url, /\.host\./, 'the app answered the Dial: B-leg');
    assert.match(move.body.aleg_url, /\.guest\./);
    assert.equal(added.json.participants[1].label, '+919876543210');
  } finally {
    await ctx.stop();
  }
});

test('two adds at once for one call share one room: the call is moved once', async () => {
  const fake = vobiz();
  const ctx = await startBridge({
    env: { VOBIZ_NUMBER: CALLER_ID },
    // Vobiz's answer about the live call takes a while, as over a network.
    apiHandler: async (method, pathname, body) => {
      if (method === 'GET') await sleep(50);
      return fake(method, pathname, body);
    },
  });
  try {
    const alice = appAuth('alice');
    const [one, two] = await Promise.all([
      postJson(ctx, '/conference/add', { call_uuid: CALL, number: '+919811111111' }, alice),
      postJson(ctx, '/conference/add', { call_uuid: CALL, number: '+919822222222' }, alice),
    ]);
    assert.equal(one.status, 200, one.text);
    assert.equal(two.status, 200, two.text);
    assert.equal(one.json.room, two.json.room, 'one room');
    assert.equal(calls(ctx, 'POST', `/Call/${CALL}/`).length, 1, 'both sides of the call moved once');
    assert.equal(calls(ctx, 'POST', '/Call/').length, 2, 'both people dialled');
    const state = (await postJson(ctx, '/conference/state', { call_uuid: CALL }, alice)).json;
    assert.deepEqual(state.participants.map((p) => p.role), ['host', 'guest', 'added', 'added']);
  } finally {
    await ctx.stop();
  }
});

test('room webhooks must be signed and their paths written by the bridge', async () => {
  const c = await startConference();
  try {
    const hostPath = pathOf(c.move.body.aleg_url);
    assert.equal((await webhook(c.ctx, hostPath, { CallUUID: CALL }, { sign: false })).status, 403);
    const forged = hostPath.replace(/\.host\.[^/]+$/, '.host.AAAAAAAAAAAAAAAAAAAAAA');
    const reply = await webhook(c.ctx, forged, { CallUUID: CALL });
    assert.match(reply.text, /<Hangup\/>/);
    const guestAsHost = hostPath.replace('.host.', '.guest.');
    assert.match((await webhook(c.ctx, guestAsHost, { CallUUID: CALL })).text, /<Hangup\/>/, 'the tag covers the role');
  } finally {
    await c.ctx.stop();
  }
});

test('in a conference the connection watch does not beep, and a lost host ends the room after CONF_HOST_LOST_SECONDS', async () => {
  const ctx = await startBridge({
    env: { VOBIZ_NUMBER: CALLER_ID },
    apiHandler: vobiz(),
    // The one-to-one reconnect window is far longer: the room must not wait for it.
    deps: { lostBeepMs: 100, lostHangupMs: 30000, confHostLostMs: 300, watchTickMs: 20 },
  });
  try {
    const alice = appAuth('alice');
    const added = await postJson(ctx, '/conference/add', { call_uuid: CALL, number: '+919811111111' }, alice);
    assert.equal(added.status, 200);
    await postJson(ctx, '/call/alive', { call_uuid: CALL }, alice);
    const lastReport = Date.now();
    const ended = await until(() => calls(ctx, 'DELETE', `/Conference/${added.json.room}/`)[0], 3000);
    assert.ok(ended, 'the room was ended once the host had been silent for CONF_HOST_LOST_SECONDS');
    assert.ok(Date.now() - lastReport >= 300, 'not before the host had been silent that long');
    assert.equal(calls(ctx, 'POST', `/Call/${CALL}/Play/`).length, 0, 'no beep into a conference');
    await sleep(50);
    assert.equal(calls(ctx, 'DELETE', `/Call/${CALL}/`).length, 0, 'the room is ended, not one leg');
  } finally {
    await ctx.stop();
  }
});
