// Access tokens: POST /token mints a JWT through the Vobiz API for the app
// (bridge key), and an app signed in with one is the SIP user
// "<sub>_<auth id>", which ROUTES can ring.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { AUTH_ID, BRIDGE_KEY, answerCall, appAuth, postJson, startBridge } from './helpers.mjs';

/** A fake Vobiz API that mints `minted-<sub>` tokens. */
function tokenApi(calls) {
  return (method, pathname, body) => {
    if (pathname === '/JWT/Token/') {
      calls.push(body);
      return { token: `minted-${body.sub}` };
    }
    return { message: 'ok' };
  };
}

test('/token needs the bridge key; a bad X-Bridge-User is refused', async (t) => {
  const minted = [];
  const ctx = await startBridge({ apiHandler: tokenApi(minted) });
  t.after(ctx.stop);
  assert.equal((await postJson(ctx, '/token', {})).status, 401);
  assert.equal((await postJson(ctx, '/token', {}, { Authorization: 'Bearer abc.def' })).status, 401, 'device tokens are gone');
  assert.equal((await postJson(ctx, '/token', {}, { 'X-Bridge-Key': 'wrong-key-0123456789' })).status, 401);
  assert.equal((await postJson(ctx, '/token', {}, appAuth(''))).status, 400, 'an empty X-Bridge-User is not the key holder');
  assert.equal((await postJson(ctx, '/token', {}, appAuth('not a user'))).status, 400);
  assert.deepEqual(minted, []);

  assert.equal((await postJson(ctx, '/token', { reason: 'sign_in' }, appAuth())).status, 200);
  assert.equal((await postJson(ctx, '/token', { reason: 'refresh' }, appAuth(`flutter-app_${AUTH_ID}`))).status, 200);
  assert.equal(minted.length, 2);
});

test('/token mints with the account as issuer, both grants and the configured lifetime', async (t) => {
  const minted = [];
  const ctx = await startBridge({ apiHandler: tokenApi(minted), env: { JWT_TTL_SECONDS: '600' } });
  t.after(ctx.stop);
  const before = Math.floor(Date.now() / 1000);
  const r = await postJson(ctx, '/token', { reason: 'sign_in' }, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(r.status, 200);
  assert.equal(minted.length, 1);
  const claims = minted[0];
  assert.equal(claims.iss, AUTH_ID);
  assert.equal(claims.sub, 'flutter-app');
  // A minute in the past, so a registrar clock a little behind does not say 10005.
  assert.ok(claims.nbf >= before - 62 && claims.nbf <= before - 58, `nbf ${claims.nbf} vs ${before}`);
  assert.equal(claims.exp - claims.nbf, 600);
  assert.deepEqual(claims.per, { voice: { incoming_allow: true, outgoing_allow: true } });
  assert.equal('app' in claims, false, 'no app claim unless JWT_APP_ID is set');
  assert.ok(ctx.logs.some((l) => l.includes('JWT_APP_ID is not set')), 'warns once about the missing app');
  // The reply has the Vobiz WebRTC demo's shape.
  assert.deepEqual(r.json, {
    token: 'minted-flutter-app',
    sub: 'flutter-app',
    exp: claims.exp,
    sip_username: `flutter-app_${AUTH_ID}`,
  });
});

test('/token takes sub from the body or ?sub=, and JWT_APP_ID as the app claim', async (t) => {
  const minted = [];
  const ctx = await startBridge({ apiHandler: tokenApi(minted), env: { JWT_APP_ID: '12345678901234567' } });
  t.after(ctx.stop);
  const fromQuery = await postJson(ctx, '/token?sub=agent42', {}, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(fromQuery.json.sip_username, `agent42_${AUTH_ID}`);
  const fromBody = await postJson(ctx, '/token', { sub: 'agent43' }, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(fromBody.json.sub, 'agent43');
  assert.deepEqual(minted.map((c) => c.app), ['12345678901234567', '12345678901234567']);

  // The platform's own sub rule: letters, digits, _ and -, at most 50.
  for (const sub of ['no spaces allowed', 'dots.are.not.allowed', 'x'.repeat(51)]) {
    const bad = await postJson(ctx, '/token', { sub }, { 'X-Bridge-Key': BRIDGE_KEY });
    assert.equal(bad.status, 400, sub);
  }
  assert.equal(minted.length, 2);
});

test('JWT_ALLOWED_SUBS limits the subs /token mints; JWT_SUB is always allowed', async (t) => {
  const minted = [];
  const ctx = await startBridge({ apiHandler: tokenApi(minted), env: { JWT_SUB: 'desk', JWT_ALLOWED_SUBS: 'agent42, agent43' } });
  t.after(ctx.stop);
  assert.equal(ctx.bridge.config.jwtAllowedSubs.join(','), 'agent42,agent43');
  const refused = await postJson(ctx, '/token', { sub: 'agent44' }, appAuth());
  assert.equal(refused.status, 403);
  assert.match(refused.json.error, /does not mint tokens for agent44/);
  assert.equal((await postJson(ctx, '/token?sub=boss', {}, appAuth())).status, 403);
  assert.deepEqual(minted, [], 'nothing was minted for a sub outside the list');

  assert.equal((await postJson(ctx, '/token', { sub: 'agent43' }, appAuth())).json.sub, 'agent43');
  assert.equal((await postJson(ctx, '/token', {}, appAuth())).json.sub, 'desk');
  assert.deepEqual(minted.map((c) => c.sub), ['agent43', 'desk']);
});

test('/token reports a Vobiz refusal as 502', async (t) => {
  const ctx = await startBridge({
    apiHandler: (method, pathname) => {
      if (pathname === '/JWT/Token/') throw new Error('POST /JWT/Token/ → 400 invalid app');
      return { message: 'ok' };
    },
  });
  t.after(ctx.stop);
  const r = await postJson(ctx, '/token', {}, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(r.status, 502);
  assert.ok(ctx.logs.some((l) => l.includes('could not mint an access token')));
});

test('a token identity <sub>_<auth id> listed in ROUTES is rung as a <User>', async (t) => {
  const ctx = await startBridge({ env: { ROUTES: `+918000000001=agent42_${AUTH_ID}` } });
  t.after(ctx.stop);
  const call = await answerCall(ctx, { CallUUID: 'c1', From: '+919800000001', To: '+918000000001' });
  assert.match(call.text, new RegExp(`<User [^>]*>sip:agent42_${AUTH_ID}@registrar\\.vobiz\\.ai</User>`));
});
