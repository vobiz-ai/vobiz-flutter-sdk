// Nothing a client sends may stop the server: requests it cannot parse are
// refused, and the next request is served as usual.
import assert from 'node:assert/strict';
import net from 'node:net';
import { test } from 'node:test';
import { startBridge } from './helpers.mjs';

/** Sends `head` as a raw HTTP/1.1 request and resolves with the status line ('' if the socket just closed). */
function rawRequest(ctx, head) {
  const { hostname, port } = new URL(ctx.base);
  return new Promise((resolve) => {
    const socket = net.connect(Number(port), hostname, () => socket.write(head));
    // A server that died, or never answers, must fail the test, not hang it.
    socket.setTimeout(2000, () => socket.destroy());
    let data = '';
    socket.on('data', (chunk) => { data += chunk; });
    socket.on('error', () => resolve(data.split('\r\n')[0]));
    socket.on('close', () => resolve(data.split('\r\n')[0]));
  });
}

test('a request target that is not a URL (//, /\\, http://[) is refused, and the server keeps running', async (t) => {
  const ctx = await startBridge();
  t.after(ctx.stop);
  for (const target of ['//', '///', '/\\', 'http://[']) {
    const status = await rawRequest(ctx, `GET ${target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`);
    assert.match(status, /^HTTP\/1\.1 400 /, `GET ${target}`);
    const health = await fetch(`${ctx.base}/health`);
    assert.equal(health.status, 200, `still up after GET ${target}`);
  }
});
