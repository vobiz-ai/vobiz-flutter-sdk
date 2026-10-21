import assert from 'node:assert/strict';
import { test } from 'node:test';
import { startBridge } from './helpers.mjs';

test('health and ringback are served', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  const health = await (await fetch(`${ctx.base}/health`)).json();
  assert.equal(health.ok, true);
  const wav = await fetch(`${ctx.base}/ringback.wav`);
  assert.equal(wav.headers.get('content-type'), 'audio/wav');
  assert.equal((await wav.arrayBuffer()).byteLength, 44 + 8000 * 3 * 2);
});

test('unknown routes are 404', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  assert.equal((await fetch(`${ctx.base}/nope`)).status, 404);
});
