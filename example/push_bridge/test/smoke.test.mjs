import assert from 'node:assert/strict';
import { test } from 'node:test';
import { startBridge } from './helpers.mjs';

test('health and the audio files are served', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const health = await (await fetch(`${ctx.base}/health`)).json();
  assert.equal(health.ok, true);
  assert.equal(health.service, 'vobiz-push-bridge');
  for (const name of ['busy', 'lost', 'hold']) {
    const wav = await fetch(`${ctx.base}/${name}.wav`);
    assert.equal(wav.status, 200, name);
    assert.equal(wav.headers.get('content-type'), 'audio/wav', name);
    const bytes = (await wav.arrayBuffer()).byteLength;
    if (name === 'busy') assert.equal(bytes, 44 + 8000 * 3 * 2, 'busy.wav is 3 s of 8 kHz audio');
  }
});

test('unknown routes, and the routes of the server\'s old push path, are 404', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  assert.equal((await fetch(`${ctx.base}/nope`)).status, 404);
  assert.equal((await fetch(`${ctx.base}/wait.wav`)).status, 404);
  for (const route of ['/push/register', '/push/unregister', '/push/test', '/push/accept', '/push/decline', '/push/registered', '/dial-now/x.y', '/declined/x.y']) {
    assert.equal((await fetch(`${ctx.base}${route}`, { method: 'POST' })).status, 404, route);
  }
});
