// Access tokens: POST /token mints a JWT through the Vobiz API for a paired
// phone, and a phone signed in with one registers as "<sub>_<auth id>".
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { AUTH_ID, BRIDGE_KEY, fcmToken, postJson, registerDevice, startBridge } from './helpers.mjs';

/** A fake Vobiz API that mints `minted-<sub>` tokens and lists the usual endpoints. */
function tokenApi(calls) {
  return (method, pathname, body) => {
    if (pathname === '/JWT/Token/') {
      calls.push(body);
      return { token: `minted-${body.sub}` };
    }
    if (pathname.startsWith('/Endpoint/')) {
      return { objects: [{ username: 'alice' }], meta: { total_count: 1 } };
    }
    return { message: 'ok' };
  };
}

test('/token needs the bridge key or a paired phone\'s device token', async (t) => {
  const minted = [];
  const ctx = await startBridge({ apiHandler: tokenApi(minted) });
  t.after(ctx.stop);
  assert.equal((await postJson(ctx, '/token', {})).status, 401);
  assert.equal((await postJson(ctx, '/token', {}, { Authorization: 'Bearer abc.def' })).status, 401);
  assert.deepEqual(minted, []);

  const alice = await registerDevice(ctx, 'alice');
  const r = await postJson(ctx, '/token', { reason: 'sign_in' }, alice.auth);
  assert.equal(r.status, 200);
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

test('/token reports a Vobiz refusal as 502', async (t) => {
  const ctx = await startBridge({
    apiHandler: (method, pathname) => {
      if (pathname === '/JWT/Token/') throw new Error('POST /JWT/Token/ → 400 invalid app');
      return { objects: [], meta: { total_count: 0 } };
    },
  });
  t.after(ctx.stop);
  const r = await postJson(ctx, '/token', {}, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(r.status, 502);
  assert.ok(ctx.logs.some((l) => l.includes('could not mint an access token')));
});

test('a phone signed in with a token registers as <sub>_<auth id>; another account\'s suffix is refused', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const ok = await postJson(ctx, '/push/register',
    { username: `agent42_${AUTH_ID}`, token: fcmToken('tok') }, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(ok.status, 200);
  assert.deepEqual(Object.values(ctx.bridge.state.devices).map((d) => d.username), [`agent42_${AUTH_ID}`]);

  const foreign = await postJson(ctx, '/push/register',
    { username: 'agent42_MA_SOMEONEELSE', token: fcmToken('x') }, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(foreign.status, 403);
  const bare = await postJson(ctx, '/push/register',
    { username: `_${AUTH_ID}`, token: fcmToken('y') }, { 'X-Bridge-Key': BRIDGE_KEY });
  assert.equal(bare.status, 403);
});
