// Test helpers: a bridge on a free port with a fake Vobiz API.
// Nothing here talks to the network beyond localhost.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createBridge } from '../push-bridge.mjs';

export const PUBLIC_URL = 'https://bridge.example.test';
export const AUTH_TOKEN = 'test-auth-token-not-a-secret';
export const AUTH_ID = 'MA_TESTTEST';
export const BRIDGE_KEY = 'test-bridge-key-0123456789';

/** The app's headers: the bridge key, and the SIP user it is signed in as when `user` is given. */
export function appAuth(user) {
  return { 'X-Bridge-Key': BRIDGE_KEY, ...(user === undefined ? {} : { 'X-Bridge-User': user }) };
}

/**
 * Starts a bridge. `env` is merged over a signed, fully configured default.
 * Returns { bridge, base, api, logs, stateFile, stop }.
 */
export async function startBridge({ env = {}, stateFile, apiHandler, deps = {} } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'push-bridge-test-'));
  const file = stateFile || path.join(dir, 'bridge-state.json');
  const api = [];
  const logs = [];
  const bridge = createBridge({
    env: {
      PUBLIC_URL,
      VOBIZ_AUTH_TOKEN: AUTH_TOKEN,
      VOBIZ_AUTH_ID: AUTH_ID,
      BRIDGE_KEY,
      RING_SECONDS: '45',
      ...env,
    },
    stateFile: file,
    deps: {
      log: (tag, message) => logs.push(`${tag} ${message}`),
      vobizApi: async (method, pathname, body) => {
        api.push({ method, pathname, body });
        if (apiHandler) return apiHandler(method, pathname, body);
        return { message: 'ok' };
      },
      ...deps,
    },
  });
  const port = await bridge.start({ port: 0, checks: false });
  const base = `http://127.0.0.1:${port}`;
  return {
    bridge,
    base,
    api,
    logs,
    stateFile: file,
    stop: () => bridge.close(),
  };
}

/** V3 signature headers as Vobiz sends them: HMAC over base URL (no query) + "." + nonce. */
export function signV3(fullUrl, { token = AUTH_TOKEN, nonce } = {}) {
  const u = new URL(fullUrl);
  const baseUrl = `${u.protocol}//${u.host}${u.pathname}`;
  const n = nonce || String(crypto.randomInt(1e9)) + String(crypto.randomInt(1e9));
  const signature = crypto.createHmac('sha256', token).update(`${baseUrl}.${n}`).digest('base64');
  return { 'X-Vobiz-Signature-V3': signature, 'X-Vobiz-Signature-V3-Nonce': n };
}

/**
 * Sends a Vobiz-style form webhook to `pathAndQuery` (as Vobiz would call
 * PUBLIC_URL + pathAndQuery), signed unless `sign` is false.
 */
export async function webhook(ctx, pathAndQuery, params = {}, { sign = true, headers = {} } = {}) {
  const signed = sign ? signV3(`${PUBLIC_URL}${pathAndQuery}`) : {};
  const response = await fetch(`${ctx.base}${pathAndQuery}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', ...signed, ...headers },
    body: new URLSearchParams(params).toString(),
  });
  return { status: response.status, text: await response.text(), headers: signed };
}

export async function postJson(ctx, pathname, body, headers = {}) {
  const response = await fetch(`${ctx.base}${pathname}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: response.status, json, text };
}

/** Pulls an attribute value out of returned XML. */
export function xmlAttr(xml, element, attr) {
  const m = xml.match(new RegExp(`<${element}[^>]*\\s${attr}="([^"]*)"`));
  return m ? m[1].replace(/&amp;/g, '&') : null;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Waits until fn() is truthy, up to `ms`. 5 s, not 2: with every test file
 * starting bridges in parallel, a callback can take over 2 s on a loaded
 * machine; a passing check returns at once.
 */
export async function until(fn, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await sleep(10);
  }
  return fn();
}

/**
 * An inbound call: Vobiz asks /answer, which replies with the Dial at once.
 * Returns { text: the Dial XML, headers: the signature sent, action and
 * events: the Dial's callback paths }.
 */
export async function answerCall(ctx, params) {
  const answer = await webhook(ctx, '/answer', params);
  const action = xmlAttr(answer.text, 'Dial', 'action');
  const events = xmlAttr(answer.text, 'Dial', 'callbackUrl');
  return {
    text: answer.text,
    headers: answer.headers,
    action: action && new URL(action).pathname,
    events: events && new URL(events).pathname,
  };
}
