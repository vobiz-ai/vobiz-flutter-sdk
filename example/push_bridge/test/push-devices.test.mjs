// Vobiz push sign-up through the server: the app's VobizPushDevices posts to
// /push/devices/*, and the server forwards to Vobiz with the account's own
// credentials, for the app's own SIP user only, and relays Vobiz's answer.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { AUTH_ID, AUTH_TOKEN, BRIDGE_KEY, appAuth, requestJson, startBridge } from './helpers.mjs';

const PUSH_TOKEN = `fcm-token-${'x'.repeat(60)}`;

/** The body VobizPushDevices.register sends (lib/src/push/vobiz_push_devices.dart). */
function device(fields = {}) {
  return {
    device_id: 'install-0001',
    push_token: PUSH_TOKEN,
    platform: 'android',
    push_type: 'voip',
    app_bundle_id: 'ai.vobiz.vobiz_webrtc_example',
    app_version: '1.0.0',
    sdk_version: '0.2.0',
    sip_username: 'alice',
    ...fields,
  };
}

/**
 * A bridge whose account has the endpoints `endpoints` (20 a page, as Vobiz
 * pages them), and a fake fetch for the push service that answers `reply()`.
 * ctx.sent lists what reached the push service.
 */
async function startPushBridge({ endpoints = ['alice', 'bob'], reply = () => ({ status: 200, body: { message: 'Device registered' } }), env } = {}) {
  const sent = [];
  const ctx = await startBridge({
    env,
    apiHandler: (method, pathname) => {
      if (method === 'GET' && pathname.startsWith('/Endpoint/')) {
        const offset = Number(new URL(pathname, 'https://x').searchParams.get('offset') || 0);
        return { objects: endpoints.slice(offset, offset + 20).map((username) => ({ username })), meta: { total_count: endpoints.length } };
      }
      return { message: 'ok' };
    },
    deps: {
      fetch: async (url, init) => {
        sent.push({ url: String(url), method: init.method, headers: init.headers, body: JSON.parse(init.body) });
        const r = await reply();
        return new Response(typeof r.body === 'string' ? r.body : JSON.stringify(r.body), { status: r.status, headers: { 'Content-Type': 'application/json' } });
      },
    },
  });
  ctx.sent = sent;
  return ctx;
}

const register = (ctx, body, headers) => requestJson(ctx, 'POST', '/push/devices/register', body, headers);
const logout = (ctx, body, headers) => requestJson(ctx, 'DELETE', '/push/devices/logout', body, headers);

test('register goes to Vobiz with the account\'s credentials and auth_id, and Vobiz\'s answer comes back', async (t) => {
  const ctx = await startPushBridge();
  t.after(ctx.stop);
  const r = await register(ctx, device({ auth_id: 'MA_SOMEONEELSE' }), appAuth('alice'));
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json, { message: 'Device registered' });

  assert.equal(ctx.sent.length, 1);
  const out = ctx.sent[0];
  assert.equal(out.method, 'POST');
  assert.equal(out.url, 'https://api.vobiz.ai/api/v1/devices/register');
  assert.equal(out.headers['X-Auth-ID'], AUTH_ID);
  assert.equal(out.headers['X-Auth-Token'], AUTH_TOKEN);
  assert.deepEqual(out.body, { ...device(), auth_id: AUTH_ID }, 'the SDK\'s body, with this account\'s auth_id whatever the app sent');
  assert.ok(ctx.logs.some((l) => /device install- signed up for alice/.test(l)), 'the log names 8 characters of the device id');
});

test('register is only for the app\'s own SIP user, and only one of this account\'s', async (t) => {
  const ctx = await startPushBridge();
  t.after(ctx.stop);
  assert.equal((await register(ctx, device())).status, 401, 'no bridge key');
  assert.equal((await register(ctx, device(), { 'X-Bridge-Key': 'wrong-key-0123456789', 'X-Bridge-User': 'alice' })).status, 401);
  assert.equal((await register(ctx, device(), appAuth())).status, 401, 'the key without X-Bridge-User');
  assert.equal((await register(ctx, device(), appAuth(''))).status, 400, 'an empty X-Bridge-User');
  assert.equal((await register(ctx, device({ sip_username: 'bob' }), appAuth('alice'))).status, 403, 'alice cannot sign up a phone for bob');
  assert.equal((await register(ctx, device({ sip_username: 'Alice' }), appAuth('alice'))).status, 403);
  assert.equal((await register(ctx, device({ sip_username: 'mallory' }), appAuth('mallory'))).status, 403, 'not an endpoint of this account');
  assert.equal((await register(ctx, device({ sip_username: 'agent42_MA_SOMEONEELSE' }), appAuth('agent42_MA_SOMEONEELSE'))).status, 403, 'another account\'s token identity');
  assert.equal((await register(ctx, device({ sip_username: undefined }), appAuth('alice'))).status, 400);
  assert.equal((await register(ctx, device({ push_token: '' }), appAuth('alice'))).status, 400);
  assert.equal((await register(ctx, device({ device_id: 42 }), appAuth('alice'))).status, 400);
  assert.equal((await register(ctx, device({ push_token: 'x'.repeat(5000) }), appAuth('alice'))).status, 400);
  assert.equal(ctx.sent.length, 0, 'nothing reached Vobiz');
});

test('an access-token identity <sub>_<auth id> can sign up its phone', async (t) => {
  const ctx = await startPushBridge({ endpoints: [] });
  t.after(ctx.stop);
  const user = `agent42_${AUTH_ID}`;
  const r = await register(ctx, device({ sip_username: user }), appAuth(user));
  assert.equal(r.status, 200, r.text);
  assert.equal(ctx.sent[0].body.sip_username, user);
});

test('an endpoint past the first page is found: Vobiz lists 20 a page whatever the limit', async (t) => {
  const endpoints = Array.from({ length: 45 }, (_, i) => `user${i}`);
  const ctx = await startPushBridge({ endpoints });
  t.after(ctx.stop);
  const r = await register(ctx, device({ sip_username: 'user30' }), appAuth('user30'));
  assert.equal(r.status, 200, r.text);
  const offsets = ctx.api.filter((c) => c.pathname.startsWith('/Endpoint/'))
    .map((c) => Number(new URL(c.pathname, 'https://x').searchParams.get('offset')));
  assert.deepEqual(offsets, [0, 20, 40]);
});

test('Vobiz\'s refusal is relayed with its status, and never carries a secret back', async (t) => {
  let other = null;
  const ctx = await startPushBridge({
    reply: () => other ?? ({ status: 403, body: { message: 'auth_id does not match authenticated account', echo: { quoted: `${PUSH_TOKEN}/${AUTH_TOKEN}/${BRIDGE_KEY}` } } }),
  });
  t.after(ctx.stop);
  const r = await register(ctx, device(), appAuth('alice'));
  assert.equal(r.status, 403);
  assert.equal(r.json.message, 'auth_id does not match authenticated account');
  assert.deepEqual(r.json.echo, { quoted: '[hidden]/[hidden]/[hidden]' });
  assert.ok(ctx.logs.some((l) => /Vobiz refused to sign up device install- for alice \(403: auth_id does not match/.test(l)));

  // A device record Vobiz sends back keeps its fields, but not a token it names.
  other = { status: 200, body: { device: { device_id: 'install-0001', push_token: 'another-token', fcm_token: 'x' } } };
  const out = await logout(ctx, { device_id: 'install-0001' }, appAuth('alice'));
  assert.deepEqual(out.json, { device: { device_id: 'install-0001', push_token: '[hidden]', fcm_token: '[hidden]' } });
  other = { status: 500, body: 'not json' };
  const text = await register(ctx, device(), appAuth('alice'));
  assert.equal(text.status, 500);
  assert.deepEqual(text.json, { error: 'not json' });
});

test('Vobiz out of reach is a 502; endpoints that cannot be listed are a 503; no credentials is a 503', async () => {
  const down = await startPushBridge({ reply: () => { throw new TypeError('fetch failed'); } });
  try {
    const r = await register(down, device(), appAuth('alice'));
    assert.equal(r.status, 502);
    assert.deepEqual(r.json, { error: 'Vobiz could not be reached' });
  } finally {
    await down.stop();
  }

  const noList = await startBridge({ apiHandler: () => { throw new Error('GET /Endpoint/ → 500 boom'); }, deps: { fetch: async () => { throw new Error('not reached'); } } });
  try {
    assert.equal((await register(noList, device(), appAuth('alice'))).status, 503);
  } finally {
    await noList.stop();
  }

  const unset = await startPushBridge({ env: { VOBIZ_AUTH_ID: '' } });
  try {
    assert.equal((await register(unset, device(), appAuth('alice'))).status, 503);
    assert.equal((await logout(unset, { device_id: 'install-0001' }, appAuth('alice'))).status, 503);
    assert.equal(unset.sent.length, 0);
  } finally {
    await unset.stop();
  }
});

test('logout goes to Vobiz with the device id and the account\'s credentials', async (t) => {
  const ctx = await startPushBridge({ reply: () => ({ status: 200, body: { message: 'Device logged out' } }) });
  t.after(ctx.stop);
  assert.equal((await logout(ctx, { device_id: 'install-0001' })).status, 401, 'no bridge key');
  assert.equal((await logout(ctx, { device_id: 'install-0001' }, appAuth(''))).status, 400, 'an empty X-Bridge-User');
  assert.equal((await logout(ctx, {}, appAuth('alice'))).status, 400, 'no device id');
  assert.equal(ctx.sent.length, 0);

  const r = await logout(ctx, { device_id: 'install-0001' }, appAuth('alice'));
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json, { message: 'Device logged out' });
  const out = ctx.sent[0];
  assert.equal(out.method, 'DELETE');
  assert.equal(out.url, 'https://api.vobiz.ai/api/v1/devices/logout');
  assert.equal(out.headers['X-Auth-ID'], AUTH_ID);
  assert.equal(out.headers['X-Auth-Token'], AUTH_TOKEN);
  assert.deepEqual(out.body, { device_id: 'install-0001' });

  // Signed out already, the app may have no SIP user to name: the key is enough.
  assert.equal((await logout(ctx, { device_id: 'install-0001' }, appAuth())).status, 200);
});

test('no log line carries the push token, the Auth Token or the bridge key', async (t) => {
  const ctx = await startPushBridge({ reply: () => ({ status: 400, body: { message: `bad token ${PUSH_TOKEN}` } }) });
  t.after(ctx.stop);
  await register(ctx, device(), appAuth('alice'));
  await register(ctx, device({ sip_username: 'mallory' }), appAuth('mallory'));
  await logout(ctx, { device_id: 'install-0001' }, appAuth('alice'));
  assert.ok(ctx.logs.length >= 3);
  for (const line of ctx.logs) {
    for (const secret of [PUSH_TOKEN, AUTH_TOKEN, BRIDGE_KEY]) assert.ok(!line.includes(secret), line);
  }
});
