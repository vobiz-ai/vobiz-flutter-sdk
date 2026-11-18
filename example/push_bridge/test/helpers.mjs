// Test helpers: a bridge on a free port with fake Firebase and Vobiz APIs.
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

/** A long, fake FCM registration token. */
export function fcmToken(name) {
  return `fcm-${name}-${'x'.repeat(40)}`;
}

/**
 * Starts a bridge. `env` is merged over a signed, fully configured default.
 * Returns { bridge, base, pushes, api, logs, stateFile, stop }.
 */
export async function startBridge({ env = {}, stateFile, apiHandler, pushDelay, endpoints = ['alice', 'bob', 'carol'], deps = {} } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'push-bridge-test-'));
  const file = stateFile || path.join(dir, 'bridge-state.json');
  const pushes = [];
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
      sendPush: async (token, data, opts) => {
        if (pushDelay) await pushDelay();
        pushes.push({ token, data, opts });
        return { ok: true };
      },
      vobizApi: async (method, pathname, body) => {
        api.push({ method, pathname, body });
        if (apiHandler) return apiHandler(method, pathname, body);
        if (pathname.startsWith('/Endpoint/')) {
          return { objects: endpoints.map((username) => ({ username })), meta: { total_count: endpoints.length } };
        }
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
    pushes,
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
 * starting bridges in parallel, a push can take over 2 s on a loaded machine;
 * a passing check returns at once.
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
 * Pairs a phone for `username` with its own FCM token. Returns the response
 * body ({ device_id, device_token, … }) plus `auth`, the header to send later.
 */
export async function registerDevice(ctx, username, { name = username } = {}) {
  const r = await postJson(ctx, '/push/register', { username, token: fcmToken(name), platform: 'android' }, { 'X-Bridge-Key': BRIDGE_KEY });
  if (r.status !== 200) throw new Error(`register ${username}: ${r.status} ${r.text}`);
  return { ...r.json, fcm: fcmToken(name), auth: { Authorization: `Bearer ${r.json.device_token}` } };
}

/**
 * An inbound call up to its Dial. /answer holds the caller on ringback while
 * a pushed phone wakes (PreAnswer + Redirect to /dial-now); this follows the
 * Redirect as Vobiz does when the wait ends. Returns { text: the Dial XML,
 * hold: the hold XML or null, action, events }.
 */
export async function answerCall(ctx, params) {
  const answer = await webhook(ctx, '/answer', params);
  let text = answer.text;
  let hold = null;
  const redirect = text.match(/<Redirect[^>]*>([^<]+)<\/Redirect>/);
  if (redirect) {
    hold = text;
    text = (await webhook(ctx, new URL(redirect[1].replace(/&amp;/g, '&')).pathname, { CallUUID: params.CallUUID, Event: 'Redirect' })).text;
  }
  const action = xmlAttr(text, 'Dial', 'action');
  const events = xmlAttr(text, 'Dial', 'callbackUrl');
  return {
    text,
    hold,
    headers: answer.headers,
    action: action && new URL(action).pathname,
    events: events && new URL(events).pathname,
  };
}
