// Start-up: the server points VOBIZ_NUMBER at itself (finds or creates its
// application, attaches the number), and says what it will do with calls.
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { createBridge } from '../push-bridge.mjs';
import { AUTH_ID, AUTH_TOKEN, BRIDGE_KEY, PUBLIC_URL, startBridge, tempDir } from './helpers.mjs';

const NUMBER = '+918000000001';
const WANT = { answer_url: `${PUBLIC_URL}/answer`, answer_method: 'POST', hangup_url: `${PUBLIC_URL}/hangup`, hangup_method: 'POST' };

/** A fake Vobiz account with `apps` and the number NUMBER attached to `attachedTo`. */
function account({ apps = [], attachedTo = null } = {}) {
  return (method, pathname) => {
    if (method === 'GET' && pathname.startsWith('/Application/')) return { objects: apps, meta: { total_count: apps.length } };
    if (method === 'POST' && pathname === '/Application/') return { app_id: 'new-app' };
    if (method === 'GET' && pathname.startsWith('/numbers')) return { items: [{ e164: NUMBER, application_id: attachedTo }], total: 1, per_page: 100 };
    return { message: 'ok' };
  };
}

const posts = (ctx) => ctx.api.filter((c) => c.method === 'POST').map((c) => [c.pathname, c.body]);

test('no application yet: it is created with this server\'s URLs, and a free number is attached to it', async (t) => {
  const ctx = await startBridge({ env: { VOBIZ_NUMBER: '918000000001' }, apiHandler: account() });
  t.after(ctx.stop);
  await ctx.bridge.linkVobizNumber();
  assert.deepEqual(posts(ctx), [
    ['/Application/', { app_name: 'Vobiz_Flutter_Push_Bridge', ...WANT }],
    [`/numbers/${encodeURIComponent(NUMBER)}/application`, { application_id: 'new-app' }],
  ]);
});

test('an application with old URLs is updated; a number another application has is left alone unless FORCE_ATTACH', async () => {
  const apps = [{ app_id: 'mine', app_name: 'Vobiz_Flutter_Push_Bridge', answer_url: 'https://old.example/answer', hangup_url: 'https://old.example/hangup' }];
  const left = await startBridge({ env: { VOBIZ_NUMBER: NUMBER }, apiHandler: account({ apps, attachedTo: 'someone-else' }) });
  try {
    await left.bridge.linkVobizNumber();
    assert.deepEqual(posts(left), [['/Application/mine/', WANT]], 'URLs updated, number not moved');
    assert.ok(left.logs.some((l) => /attached to another application \(someone-else\); left as it is/.test(l)));
  } finally {
    await left.stop();
  }

  const moved = await startBridge({ env: { VOBIZ_NUMBER: NUMBER, FORCE_ATTACH: 'true' }, apiHandler: account({ apps, attachedTo: 'someone-else' }) });
  try {
    await moved.bridge.linkVobizNumber();
    assert.deepEqual(posts(moved).at(-1), [`/numbers/${encodeURIComponent(NUMBER)}/application`, { application_id: 'mine' }]);
  } finally {
    await moved.stop();
  }
});

/** Starts a bridge with its start-up checks, printing nothing. Returns { bridge, logs, printed }. */
async function startWithChecks(env, t) {
  const logs = [];
  const printed = [];
  const bridge = createBridge({
    env: { PUBLIC_URL, VOBIZ_AUTH_TOKEN: AUTH_TOKEN, VOBIZ_AUTH_ID: AUTH_ID, BRIDGE_KEY, ...env },
    stateFile: path.join(tempDir(), 'bridge-state.json'),
    deps: {
      log: (tag, message) => logs.push(`${tag} ${message}`),
      vobizApi: async (method, pathname) => account({ attachedTo: 'x' })(method, pathname),
      // The tunnel check reaches some other server.
      fetch: async () => new Response(JSON.stringify({ ok: true, instance: 'another-server' }), { status: 200 }),
    },
  });
  const original = console.log;
  console.log = (...args) => printed.push(args.join(' '));
  try {
    await bridge.start({ port: 0, checks: true });
  } finally {
    console.log = original;
  }
  t.after(() => bridge.close());
  return { bridge, logs, printed: printed.join('\n') };
}

test('start-up warns when no call would ring anyone and when /token mints any sub', async (t) => {
  const { logs, printed } = await startWithChecks({}, t);
  assert.ok(logs.includes('!! ROUTES and ALWAYS_RING are empty: inbound calls ring nobody. Set ROUTES=<your number>=<SIP user> in .env.'));
  assert.ok(logs.some((l) => /^!! Access tokens: \/token mints a token for any sub/.test(l)));
  assert.ok(logs.some((l) => /^!! Tunnel: .* answered, but not from this server/.test(l)));
  assert.match(printed, /Connect the app with https:\/\/bridge\.example\.test#key=<bridge key>/);
  assert.ok(!printed.includes(BRIDGE_KEY) && !logs.some((l) => l.includes(BRIDGE_KEY)), 'a key that is not new is not printed');
});

test('start-up lists the routes, links the number, and names the subs /token mints', async (t) => {
  const { logs } = await startWithChecks({ ROUTES: `${NUMBER}=alice,+919800000099`, ALWAYS_RING: 'browser1', JWT_ALLOWED_SUBS: 'agent42', VOBIZ_NUMBER: NUMBER }, t);
  assert.ok(!logs.some((l) => /ROUTES and ALWAYS_RING are empty/.test(l)));
  assert.ok(logs.includes(`.. Calls to ${NUMBER} ring alice, +919800000099`));
  assert.ok(logs.includes('.. Every inbound call also rings browser1'));
  assert.ok(logs.includes('ok Access tokens: only for flutter-app, agent42'));
  assert.ok(logs.some((l) => /Vobiz: created application Vobiz_Flutter_Push_Bridge/.test(l)), 'the number was linked');
});
